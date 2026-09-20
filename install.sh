#!/usr/bin/env bash
# Install script for agy-sessions
set -euo pipefail

INSTALL_DIR="${HOME}/.local/bin"
REPO_RAW="https://raw.githubusercontent.com/kdrai512/agy-sessions/main"

echo "==> Installing agy-sessions..."

mkdir -p "${INSTALL_DIR}"

if [[ -f "$(dirname "$0")/bin/agy-sessions" ]]; then
    # Local install from cloned repository
    cp "$(dirname "$0")/bin/agy-sessions" "${INSTALL_DIR}/agy-sessions"
else
    # Remote install via curl
    curl -fsSL "${REPO_RAW}/bin/agy-sessions" -o "${INSTALL_DIR}/agy-sessions"
fi

chmod +x "${INSTALL_DIR}/agy-sessions"
ln -sf "${INSTALL_DIR}/agy-sessions" "${INSTALL_DIR}/agys"

echo "==> Successfully installed agy-sessions and agys to ${INSTALL_DIR}"

# PATH check
if [[ ":$PATH:" != *":${INSTALL_DIR}:"* ]]; then
    echo "Notice: ${INSTALL_DIR} is not in your \$PATH."
    echo "Add the following to your ~/.bashrc or ~/.zshrc:"
    echo "  export PATH=\"\$HOME/.local/bin:\$PATH\""
fi

echo "==> Run 'agys' to get started!"
