# PORT_NOTES — records of the Node → Go port

These notes (`*.md` here and the behavioural specs in `specs/`) were written while the Node server
still lived in `server/` and cite its files — `server/src/game/table.js`, `socket/index.js`,
`test/*.test.js`, `test/helpers/csharpJsonPort.js`, `tools/bot.js` and so on. **That tree was removed
from the repository on 8 Sep 2026** (`git log -- server/`; the last commit carrying it is `c19963b`,
and the `multi_node` branch still has it), so every `server/…` path in these files names a file in
git history, not in the working tree. The notes are kept as-is because they are the record of what
was ported, how it was tested and what deviates; `../PORT_PLAN.md` §2 maps each Node file to the Go
file that implements the behaviour today, and `../DECISIONS.md` settles every ambiguity they raised.
The tooling they mention under `server/tools/` and `server/test/parity/` now lives in `../../tools/`.
