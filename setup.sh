#!/bin/bash

# This script sets up the home directory with the config files set the way I like them.
# It sets the .zshrc file, installs some zsh plugins, installs doom emacs, and sets evil to default to emacs mode.
# THIS SCRIPT REQUIRES ZSH AND EMACS TO BE INSTALLED BEFORE IT IS RUN.

# Parsing variables
DOOM_EMACS=true
ZSH_SETUP=true

# Help Function
show_help () {
    echo "This script setups up zsh and doom emacs the way I like it."
    echo
    echo "-h or -?"
    echo "  Print this help statement and exit."
    echo "-d"
    echo "  Do not setup doom emacs."
    echo "-z"
    echo "  Do not setup zsh."
}

# Parse command line options using getopts
while getopts "h?dz" opt; do
    case "$opt" in
    h|\?)
        show_help
        exit 0
        ;;
    d)  DOOM_EMACS=false
        ;;
    z)  ZSH_SETUP=false
        ;;
    esac
done

if [ ZSH_SETUP == true ]; then
    # Download .zshrc file from this repo
    echo "Downloading .zshrc..."
    curl -sS https://raw.githubusercontent.com/neboman11/dotfiles/master/.zshrc -o ~/.zshrc

    # Create .zsh folder to store the zsh plugins
    echo "Creating zsh folder to install plugins into..."
    mkdir -p ~/.zsh

    # Download the zsh plugins and place them in ~/.zsh
    echo "Downloading zsh plugins..."
    git clone https://github.com/zsh-users/zsh-syntax-highlighting.git ~/.zsh/zsh-syntax-highlighting
    git clone https://github.com/zsh-users/zsh-autosuggestions.git ~/.zsh/zsh-autosuggestions
    git clone https://github.com/zsh-users/zsh-history-substring-search.git ~/.zsh/zsh-history-substring-search
    git clone https://github.com/zsh-users/zsh-completions.git ~/.zsh/zsh-completions

    # Check if the current shell is zsh
    if [ $(echo $SHELL | awk 'BEGIN { zsh=0 } $1 ~ /zsh/ { zsh=1 } END { print zsh }') -eq 1 ]; then # The test checks if zsh is the current shell, there is probably a better way to do this
        # Source the new .zshrc file
        echo "Sourcing new .zshrc file..."
        source ~/.zshrc
    else
        # Change shell to zsh
        echo "Changing shell to zsh..."
        chsh -s $(awk '$1 ~ /zsh/ { print; exit }' /etc/shells) # This will find the first line of the /etc/shells file containing 'zsh'
    fi
fi # zsh setup

if [ DOOM_EMACS == true ]; then
    # Setup doom emacs
    echo "Downloading doom emacs..."
    if [ -d ~/.emacs.d ]; then
        rm -rf ~/.emacs.d
    fi

    git clone --depth 1 https://github.com/hlissner/doom-emacs ~/.emacs.d

    # Install doom emacs
    echo "Installing doom emacs..."
    ~/.emacs.d/bin/doom -y install

    # Set evil to default to emacs mode
    echo "Setting emacs as the default editor mode..."
    echo '(setq evil-default-state "emacs")' >> ~/.emacs.d/modules/editor/evil/config.el

    echo "Done."
fi # doom emacs setup
