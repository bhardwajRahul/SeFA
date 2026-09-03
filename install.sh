#!/usr/bin/env bash
#
# Installs SeFA into a virtual environment of its own and links the `sefa` command
# onto the PATH, so generating a schedule never needs an environment to be activated
# by hand. Run it from a checkout, or pipe it into bash and it clones one.
#
# macOS and Linux. On Windows use the manual steps in the README.

set -euo pipefail

REPO_URL="https://github.com/atulgpt/SeFA.git"
COMMAND_NAME="sefa"
# where a checkout is cloned when the script is not run from one
DEFAULT_SOURCE_DIR="$HOME/.local/share/sefa/src"
DEFAULT_BIN_DIR="$HOME/.local/bin"
# a checkout already keeps its environment here, so a developer and a taxpayer end
# up sharing one instead of building a second copy of pandas
VENV_DIR_NAME=".venv"
# what `requires-python` declares: the parsers use PEP 701 nested quote f-strings
MIN_PYTHON="3.12"

python_override=""
source_dir=""
venv_dir=""
bin_dir="$DEFAULT_BIN_DIR"
assume_yes=0
uninstall=0
python=""

usage() {
    cat <<USAGE
Usage: ./install.sh [options]
       ./install.sh --uninstall [options]
       curl -fsSL https://raw.githubusercontent.com/atulgpt/SeFA/main/install.sh | bash -s -- [options]

Installs SeFA into a virtual environment and links '$COMMAND_NAME' into a folder on
your PATH, so the command works from any shell without activating anything.

Options:
  --python PATH     Interpreter to build the environment with, default = the first
                    of python3, python3.13, python3.12, python3.14, python that is
                    Python $MIN_PYTHON or higher
  --source DIR      SeFA checkout to install from, default = the folder this script
                    sits in. A folder that does not exist yet is cloned from
                    $REPO_URL
  --venv-dir DIR    Virtual environment to build, default = <source>/$VENV_DIR_NAME
  --bin-dir DIR     Folder the '$COMMAND_NAME' link goes into, default = $DEFAULT_BIN_DIR
  --uninstall       Remove the '$COMMAND_NAME' link and the virtual environment
  -y, --yes         Answer every prompt with yes
  -h, --help        Show this message
USAGE
}

log() {
    printf '%s\n' "$*"
}

die() {
    printf '%s\n' "$*" >&2
    exit 1
}

confirm() {
    local reply
    if [ "$assume_yes" -eq 1 ]; then
        return 0
    fi
    if [ ! -t 0 ]; then
        log "Skipping: $1 (no terminal to ask on, pass --yes to answer for it)"
        return 1
    fi
    printf '%s [y/N] ' "$1"
    read -r reply
    case "$reply" in
        [yY] | [yY][eE][sS]) return 0 ;;
        *) return 1 ;;
    esac
}

python_version() {
    "$1" -c 'import sys; print(".".join(str(part) for part in sys.version_info[:3]))' 2>/dev/null || printf 'unknown\n'
}

python_supported() {
    "$1" -c "import sys; want = tuple(int(part) for part in '$MIN_PYTHON'.split('.')); raise SystemExit(0 if sys.version_info >= want else 1)" >/dev/null 2>&1
}

resolve_python() {
    local candidate resolved
    if [ -n "$python_override" ]; then
        resolved="$(command -v "$python_override" 2>/dev/null || true)"
        if [ -z "$resolved" ]; then
            die "--python $python_override is not an executable on this system"
        fi
        if ! python_supported "$resolved"; then
            die "--python $python_override is Python $(python_version "$resolved"), and SeFA needs $MIN_PYTHON or higher"
        fi
        python="$resolved"
        return
    fi
    # the default interpreter first, then the versions CI covers, and a newer
    # release last: a dependency does not always have wheels for one on day one
    for candidate in python3 python3.13 python3.12 python3.14 python; do
        resolved="$(command -v "$candidate" 2>/dev/null || true)"
        if [ -n "$resolved" ] && python_supported "$resolved"; then
            python="$resolved"
            return
        fi
    done
    die "Found no Python $MIN_PYTHON or higher on the PATH (looked for python3,
python3.13, python3.12, python3.14, python). Install one with 'brew install
python@$MIN_PYTHON' on macOS or your distribution's python$MIN_PYTHON package, or point
this script at an interpreter with --python"
}

is_checkout() {
    [ -f "$1/pyproject.toml" ] && grep -q '^name = "SeFA"$' "$1/pyproject.toml"
}

self_dir() {
    local self="${BASH_SOURCE[0]:-}"
    # a real file for a checkout, and not one when the script is piped in from curl
    if [ -n "$self" ] && [ -f "$self" ]; then
        (cd "$(dirname "$self")" && pwd)
    fi
}

clone_source() {
    local target="$1"
    if ! command -v git >/dev/null 2>&1; then
        die "git is needed to clone $REPO_URL into $target. Install git, or clone the
repository yourself and run its install.sh"
    fi
    log "Cloning $REPO_URL into $target"
    mkdir -p "$(dirname "$target")"
    git clone --depth 1 "$REPO_URL" "$target"
}

resolve_source() {
    local here
    if [ -n "$source_dir" ]; then
        if [ ! -e "$source_dir" ]; then
            clone_source "$source_dir"
        elif ! is_checkout "$source_dir"; then
            die "--source $source_dir holds no SeFA pyproject.toml, so it is not a
SeFA checkout"
        fi
        source_dir="$(cd "$source_dir" && pwd)"
        return
    fi
    here="$(self_dir)"
    if [ -n "$here" ] && is_checkout "$here"; then
        source_dir="$here"
        return
    fi
    if [ -e "$DEFAULT_SOURCE_DIR" ]; then
        if ! is_checkout "$DEFAULT_SOURCE_DIR"; then
            die "$DEFAULT_SOURCE_DIR exists and is not a SeFA checkout. Remove it, or
pass --source <your checkout>"
        fi
        log "Updating the checkout at $DEFAULT_SOURCE_DIR"
        git -C "$DEFAULT_SOURCE_DIR" pull --ff-only ||
            log "Could not fast forward $DEFAULT_SOURCE_DIR, installing what it already holds"
    else
        clone_source "$DEFAULT_SOURCE_DIR"
    fi
    source_dir="$(cd "$DEFAULT_SOURCE_DIR" && pwd)"
}

resolve_venv_dir() {
    if [ -z "$venv_dir" ]; then
        venv_dir="$source_dir/$VENV_DIR_NAME"
    fi
}

ensure_venv() {
    if [ -x "$venv_dir/bin/python" ]; then
        if ! python_supported "$venv_dir/bin/python"; then
            die "The virtual environment at $venv_dir runs Python $(python_version "$venv_dir/bin/python"),
and SeFA needs $MIN_PYTHON or higher. Remove it with 'rm -rf $venv_dir' and run this
script again, or build a separate one with --venv-dir <folder>"
        fi
        log "Reusing the virtual environment at $venv_dir"
        return
    fi
    if [ -e "$venv_dir" ]; then
        die "$venv_dir exists and holds no bin/python, so it is not a virtual
environment. Remove it, or pass --venv-dir <folder>"
    fi
    log "Creating a virtual environment at $venv_dir with $python (Python $(python_version "$python"))"
    "$python" -m venv "$venv_dir" ||
        die "'$python -m venv' failed. On Debian and Ubuntu the venv module ships
separately: 'sudo apt install python3-venv'"
}

install_package() {
    log "Installing SeFA from $source_dir"
    "$venv_dir/bin/python" -m pip install --quiet --disable-pip-version-check --upgrade pip
    # an editable install leaves the package inside the checkout, which is what keeps
    # the refreshed historic_data CSVs and the default output folder where the README
    # says they are rather than inside the virtual environment. It also means a
    # 'git pull' upgrades the command in place
    "$venv_dir/bin/python" -m pip install --disable-pip-version-check --editable "$source_dir"
}

link_command() {
    mkdir -p "$bin_dir"
    ln -sfn "$venv_dir/bin/$COMMAND_NAME" "$bin_dir/$COMMAND_NAME"
    # the link is only worth reporting as installed once what it points at runs
    "$bin_dir/$COMMAND_NAME" --help >/dev/null ||
        die "$bin_dir/$COMMAND_NAME does not run, so the install did not take"
    log "Linked $bin_dir/$COMMAND_NAME -> $venv_dir/bin/$COMMAND_NAME"
}

on_path() {
    case ":$PATH:" in
        *":$1:"*) return 0 ;;
        *) return 1 ;;
    esac
}

shell_profile() {
    case "$(basename "${SHELL:-}")" in
        zsh) printf '%s\n' "$HOME/.zshrc" ;;
        bash)
            if [ -f "$HOME/.bash_profile" ]; then
                printf '%s\n' "$HOME/.bash_profile"
            else
                printf '%s\n' "$HOME/.bashrc"
            fi
            ;;
        *) printf '' ;;
    esac
}

ensure_on_path() {
    local profile export_line
    if on_path "$bin_dir"; then
        return
    fi
    export_line="export PATH=\"$bin_dir:\$PATH\""
    profile="$(shell_profile)"
    if [ -z "$profile" ]; then
        log ""
        log "$bin_dir is not on your PATH. Add this line to your shell's startup file:"
        log "    $export_line"
        return
    fi
    if ! confirm "$bin_dir is not on your PATH. Add it in $profile?"; then
        log "Left $profile alone. Add this line to it to run '$COMMAND_NAME' from any shell:"
        log "    $export_line"
        return
    fi
    if [ -f "$profile" ] && grep -qF "$bin_dir" "$profile"; then
        log "$profile already names $bin_dir. Open a new shell to pick it up"
        return
    fi
    printf '\n# added by the SeFA installer\n%s\n' "$export_line" >>"$profile"
    log "Added $bin_dir to the PATH in $profile. Open a new shell, or run:"
    log "    $export_line"
}

run_install() {
    resolve_python
    resolve_source
    resolve_venv_dir
    ensure_venv
    install_package
    link_command
    ensure_on_path
    log ""
    log "SeFA is installed. Try:"
    log "    $COMMAND_NAME --help"
    log ""
    log "Checkout    $source_dir"
    log "Environment $venv_dir"
    log "Output      $source_dir/output, unless a run passes -o <folder>"
    log "Upgrade     git -C $source_dir pull && $source_dir/install.sh"
    log "Uninstall   $source_dir/install.sh --uninstall"
}

run_uninstall() {
    local link target
    link="$bin_dir/$COMMAND_NAME"
    if [ -z "$venv_dir" ] && [ -L "$link" ]; then
        # the link is the only record of which environment an install built
        target="$(readlink "$link")"
        venv_dir="$(dirname "$(dirname "$target")")"
    fi
    if [ -L "$link" ]; then
        rm -f "$link"
        log "Removed $link"
    else
        log "No '$COMMAND_NAME' link at $link"
    fi
    if [ -z "$venv_dir" ]; then
        log "Found no virtual environment to remove. Pass --venv-dir <folder> if it
sits somewhere this script did not look"
    # a folder without pyvenv.cfg is not a virtual environment, and is not this
    # script's to delete
    elif [ ! -f "$venv_dir/pyvenv.cfg" ]; then
        log "$venv_dir holds no pyvenv.cfg, so it is not a virtual environment and is
left alone"
    elif confirm "Remove the virtual environment at $venv_dir?"; then
        rm -rf "$venv_dir"
        log "Removed $venv_dir"
    else
        log "Left $venv_dir in place"
    fi
    log "The checkout itself is left alone, delete it yourself if you are done with it"
}

while [ $# -gt 0 ]; do
    case "$1" in
        --python | --source | --venv-dir | --bin-dir)
            if [ $# -lt 2 ]; then
                die "$1 needs a path"
            fi
            case "$1" in
                --python) python_override="$2" ;;
                --source) source_dir="$2" ;;
                --venv-dir) venv_dir="$2" ;;
                --bin-dir) bin_dir="$2" ;;
            esac
            shift 2
            ;;
        --uninstall)
            uninstall=1
            shift
            ;;
        -y | --yes)
            assume_yes=1
            shift
            ;;
        -h | --help)
            usage
            exit 0
            ;;
        *)
            usage >&2
            die "Unknown option $1"
            ;;
    esac
done

if [ "$uninstall" -eq 1 ]; then
    run_uninstall
else
    run_install
fi
