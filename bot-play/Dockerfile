# bot-play: the King Teen Patti bot fleet.
#   docker build -t bot-play bot-play/
#   docker run --rm --network host -e BOT_COUNT=10 -e SERVER_URL=http://127.0.0.1:3000 bot-play
FROM golang:1.27 AS build
WORKDIR /src
COPY go.mod go.sum ./
RUN go mod download
COPY . .
ARG VERSION=dev
RUN CGO_ENABLED=0 go build -trimpath -ldflags "-s -w -X main.version=${VERSION}" -o /out/bot-play ./cmd/bot-play

FROM gcr.io/distroless/static-debian12:nonroot
WORKDIR /app
COPY --from=build /out/bot-play /app/bot-play
COPY configs /app/configs
ENV BOT_MODE=server
ENTRYPOINT ["/app/bot-play", "-config", "configs/bot.yaml"]
