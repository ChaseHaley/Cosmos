# Cosmos agent entry point

Cosmos is the owner's Odin framework for a family of native Windows apps. Apps
import its `src` folder as the `cosmos` collection and pin a commit of it.

Project knowledge and work tracking live in the Obsidian vault, not this repository.

Vault root: `C:\Users\chale\Obsidian Vaults\Main\Main`

Before project work, read these files from the vault:

- `Cosmos/Cosmos.md`: project home and current position.
- `AIODev/System/Organization.md`: note types, statuses, linking, and maintenance.
- `AIODev/System/Idea capture.md`: when to start owner requests and how to track them.
- `AIODev/Engineering Standards.md`: follow its links to applicable engineering rules.

Cosmos work is tracked as AIODev work items in the shared `WORK-NNN` sequence until
the owner gives Cosmos its own. Follow `AIODev/System/Idea capture.md#Purpose` for
owner requests.

Packages live in `src/<name>`, tests in `tests/<name>` and developer tools in
`tools/<name>`. A Cosmos package never imports an app's collection; `build.ps1 check`
compiles every package with only `-collection:cosmos=src`.

The vault is a Git repository. Follow AIODev/System/Organization.md#Version control:
read a note before changing it, never reuse an existing ID or filename, leave others'
uncommitted changes alone, and commit your note changes in the vault before ending
the turn.

Do source work in your own git worktree and branch, never in this main checkout.
Commit completed, validated work with Conventional Commits. Never push to GitHub or
start GitHub Actions work unless the owner asks or a real AIODev release does it.
