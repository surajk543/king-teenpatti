package app

import (
	"bytes"
	_ "embed"
	"fmt"
	"io/fs"
	"mime"
	"net/http"
	"os"
	"path"
	"path/filepath"
	"strconv"
	"strings"
)

// socketIOClient is socket.io-client's browser bundle, copied verbatim from
// server/node_modules/socket.io/client-dist/socket.io.min.js (MIT; the
// licence sits next to it in assets/LICENSE). Node's Socket.IO server served
// it itself at /socket.io/socket.io.js (`serveClient: true`), and the bundled
// browser client's index.html loads it from there — so the Go server serves
// the same file at the same two paths (DECISIONS.md §1).
//
//go:embed assets/socket.io.min.js
var socketIOClient []byte

// clientBundlePaths are the URLs Socket.IO answered with its client bundle.
var clientBundlePaths = map[string]bool{
	"/socket.io/socket.io.js":     true,
	"/socket.io/socket.io.min.js": true,
}

// contentTypes are the content types serve-static (mime 1.6) sent for the
// browser client's files — Go's mime table differs for .js ("text/javascript")
// and adds charsets differently, and the Flutter client decodes by charset.
var contentTypes = map[string]string{
	".html": "text/html; charset=UTF-8",
	".htm":  "text/html; charset=UTF-8",
	".js":   "application/javascript; charset=UTF-8",
	".mjs":  "application/javascript; charset=UTF-8",
	".css":  "text/css; charset=UTF-8",
	".svg":  "image/svg+xml",
	".txt":  "text/plain; charset=UTF-8",
	".json": "application/json; charset=UTF-8",
	".png":  "image/png",
	".jpg":  "image/jpeg",
	".jpeg": "image/jpeg",
	".webp": "image/webp",
	".gif":  "image/gif",
	".ico":  "image/x-icon",
	".map":  "application/json; charset=UTF-8",
}

func contentTypeFor(name string) string {
	ext := strings.ToLower(path.Ext(name))
	if ct, ok := contentTypes[ext]; ok {
		return ct
	}
	if ct := mime.TypeByExtension(ext); ct != "" {
		return ct
	}
	return "application/octet-stream"
}

// serveClientBundle answers /socket.io/socket.io(.min).js with the embedded
// bundle. Cache headers follow serve-static so the browser revalidates.
func (a *App) serveClientBundle(w http.ResponseWriter, r *http.Request) {
	if r.Method != http.MethodGet && r.Method != http.MethodHead {
		staticNotFound(w, r)
		return
	}
	h := w.Header()
	h.Set("Content-Type", contentTypes[".js"])
	h.Set("Cache-Control", "public, max-age=0")
	h.Set("ETag", fmt.Sprintf(`W/"%x-%x"`, len(socketIOClient), a.started.Unix()))
	http.ServeContent(w, r, "socket.io.min.js", a.started, bytes.NewReader(socketIOClient))
}

// staticHandler is express.static(<root>) for the bundled browser client
// (index.js:100; spec-auth-http §2.5): GET/HEAD only, index.html at "/",
// a directory without a trailing slash redirects 301 to the slashed URL, a
// directory with no index → 404, dotfiles hidden (404), traversal impossible
// (the path is cleaned and resolved under root by http.Dir), weak ETag +
// Last-Modified + Cache-Control "public, max-age=0" on a hit, conditional
// and Range requests handled by http.ServeContent. Misses are plain-text
// 404s (DECISIONS.md §5; Express sent an HTML page nothing parses).
type staticHandler struct {
	root http.Dir
}

func (s staticHandler) ServeHTTP(w http.ResponseWriter, r *http.Request) {
	if r.Method != http.MethodGet && r.Method != http.MethodHead {
		staticNotFound(w, r)
		return
	}
	upath := r.URL.Path
	if !strings.HasPrefix(upath, "/") {
		upath = "/" + upath
	}
	clean := path.Clean(upath)
	// dotfiles: 'ignore' — any segment starting with "." is invisible.
	for _, seg := range strings.Split(clean, "/") {
		if strings.HasPrefix(seg, ".") && seg != "." && seg != ".." {
			staticNotFound(w, r)
			return
		}
	}
	f, err := s.root.Open(clean)
	if err != nil {
		staticNotFound(w, r)
		return
	}
	defer f.Close()
	info, err := f.Stat()
	if err != nil {
		staticNotFound(w, r)
		return
	}
	if info.IsDir() {
		if !strings.HasSuffix(upath, "/") {
			// serve-static: redirect to the directory with a trailing slash.
			target := upath + "/"
			if r.URL.RawQuery != "" {
				target += "?" + r.URL.RawQuery
			}
			http.Redirect(w, r, target, http.StatusMovedPermanently)
			return
		}
		f.Close()
		index := path.Join(clean, "index.html")
		f, err = s.root.Open(index)
		if err != nil {
			staticNotFound(w, r)
			return
		}
		defer f.Close()
		info, err = f.Stat()
		if err != nil || info.IsDir() {
			staticNotFound(w, r)
			return
		}
		clean = index
	}
	serveFile(w, r, clean, info, f)
}

// serveFile writes one regular file with serve-static's headers.
func serveFile(w http.ResponseWriter, r *http.Request, name string, info fs.FileInfo, f http.File) {
	h := w.Header()
	h.Set("Content-Type", contentTypeFor(name))
	h.Set("Cache-Control", "public, max-age=0")
	// serve-static's weak ETag: size and mtime in hex.
	h.Set("ETag", fmt.Sprintf(`W/"%x-%x"`, info.Size(), info.ModTime().UnixMilli()))
	http.ServeContent(w, r, filepath.Base(name), info.ModTime(), f)
}

// staticNotFound is the plain-text miss: `Cannot <METHOD> <path>` (the text
// finalhandler put inside its HTML page), as text/plain.
func staticNotFound(w http.ResponseWriter, r *http.Request) {
	h := w.Header()
	h.Set("Content-Type", "text/plain; charset=utf-8")
	h.Set("X-Content-Type-Options", "nosniff")
	h.Set("Content-Security-Policy", "default-src 'none'")
	body := "Cannot " + r.Method + " " + r.URL.Path
	h.Set("Content-Length", strconv.Itoa(len(body)))
	w.WriteHeader(http.StatusNotFound)
	if r.Method != http.MethodHead {
		_, _ = w.Write([]byte(body))
	}
}

// publicDirExists reports whether the browser client directory is usable, so
// New can warn once at boot instead of 404-ing silently.
func publicDirExists(dir string) bool {
	info, err := os.Stat(dir)
	return err == nil && info.IsDir()
}
