# ROM runner merged set

ROM scripts to work with merged sets: runner, manager

## What is a ROM merged set?

Merged set is a type of ROM set, that one package has all clones inside a compressed file.

The name of the file, is the parent name of the game.

Example `Super Street Fighter II (USA) (Rev 1).7z`, has the contents:

- Parent: `Super Street Fighter II (USA) (Rev 1).7z`
- Clone: `Super Street Fighter II (Europe).sfc`
- Clone: `Super Street Fighter II (USA).sfc`
- Clone: `Super Street Fighter II (USA) (Beta 1).sfc`

- 👍️ Advantages of using a merged set:
    - Saves a lot of storage, compressing with 7z, since all clones are almost the same
    - Cleaner organization, grouping all clones into a package
- 👎️ Disadvantages of using a merged set:
    - Sharing and hashes: 7z is not commonly used to share. Usually is used `zip` with `torrentzip`

## Why this script?

Work with merged sets can be difficult sometimes, usually gaming front-end are not prepared for this sets.

## How this script work?

This script was built thinking to use with [ES-DE](https://es-de.org/).

This script basically creates symlinks point to a parent file, each symlink created is a clone.

This has these mainly scripts:

1. `rom_manager.sh`
    1. This is a helper to read contents of a merged set and creating symlink clones.
2. `rom_runner_wrapper.sh`
    1. This is a wrapper, used before calling the emulator. MAME and Finalburn doesn't need, it is ready for merged sets.
    2. The filename must be the last parameter and must be a ".7z" file
    3. Script will read the filename, search for this filename inside the package and extract it in a /tmp folder
        1. This is why use a "symlink" for clones.
    4. Then will run the extracted file
