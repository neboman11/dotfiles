#!/usr/bin/env bash

# This script sets up the home directory with the config files set the way I like them.
# It sets the .zshrc file, installs some zsh plugins, installs doom emacs, and sets evil to default to emacs mode.
# THIS SCRIPT REQUIRES ZSH AND EMACS TO BE INSTALLED BEFORE IT IS RUN.

# Parsing variables
DOOM_EMACS=true
ZSH_SETUP=true
INSTALL_PACKAGES=false
ENABLE_OMZ_VSCODE=false
BYOBU_SETUP=true

DESIRED_PACKAGES="git zsh emacs-nox fzf tmux byobu bpytop ripgrep"

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
    echo "-i"
    echo "  Install all desired packages. (requires sudo)"
    echo "-v"
    echo "  Add the vscode plugin to OMZ."
    echo "-b"
    echo "  Disable byobu setup."
}

# Parse command line options using getopts
while getopts "h?dzivb" opt; do
    case "$opt" in
    h|\?)
        show_help
        exit 0
        ;;
    d)  DOOM_EMACS=false
        ;;
    z)  ZSH_SETUP=false
        ;;
    i)  INSTALL_PACKAGES=true
        ;;
    v)  ENABLE_OMZ_VSCODE=true
        ;;
    b)  BYOBU_SETUP=false
        ;;
    esac
done

if [ "$INSTALL_PACKAGES" = true ]; then
    # Determine which package manager to use
    PACKAGE_MANAGER=""
    if command -v pacman &> /dev/null; then
        PACKAGE_MANAGER="pacman -Sy"
    elif command -v apt &> /dev/null; then
        sudo apt update
        PACKAGE_MANAGER="apt install"
    else
        echo "Valid package manager not found!"
        exit 1
    fi

    # Install the desired packages
    sudo $PACKAGE_MANAGER $DESIRED_PACKAGES
fi # Install packages

if [ "$ZSH_SETUP" = true ]; then
    # Install oh-my-zsh
    RUNZSH=no sh -c "$(curl -fsSL https://raw.githubusercontent.com/ohmyzsh/ohmyzsh/master/tools/install.sh)"

    # Download .zshrc and .p10k.zsh from this repo
    echo "Downloading .zshrc..."
    curl -sS https://raw.githubusercontent.com/neboman11/dotfiles/master/.zshrc -o ~/.zshrc
    # curl -sS https://raw.githubusercontent.com/neboman11/dotfiles/master/.p10k.zsh -o ~/.p10k.zsh

    echo "Installing starship..."
    curl -sS https://starship.rs/install.sh | sh
    starship preset tokyo-night -o ~/.config/starship.toml

    # Download the zsh plugins and themes and place them in the oh my zsh folder
    echo "Downloading zsh plugins and themes..."
    git clone --depth 1 https://github.com/zsh-users/zsh-autosuggestions.git ${ZSH_CUSTOM:-~/.oh-my-zsh/custom}/plugins/zsh-autosuggestions
    # git clone --depth 1 https://github.com/ChesterYue/ohmyzsh-theme-passion.git ${ZSH_CUSTOM:-~/.oh-my-zsh/custom}/themes/passion
    # git clone --depth 1 https://github.com/Moarram/headline.git ${ZSH_CUSTOM:-~/.oh-my-zsh/custom}/themes/headline
    # git clone --depth 1 https://github.com/romkatv/powerlevel10k.git ${ZSH_CUSTOM:-$HOME/.oh-my-zsh/custom}/themes/powerlevel10k
fi # zsh setup

if [ "$DOOM_EMACS" = true ]; then
    # Setup doom emacs
    echo "Downloading doom emacs..."
    if [ -d ~/.emacs.d ]; then
        rm -rf ~/.emacs.d
    fi

    git clone --depth 1 https://github.com/doomemacs/doomemacs ~/.config/emacs

    # Install doom emacs
    echo "Installing doom emacs..."
    ~/.config/emacs/bin/doom install

    # Set evil to default to emacs mode
    echo "Setting emacs as the default editor mode..."
    # echo '(setq evil-default-state "emacs")' >> ~/.config/doom/config.el
    sed -i 's/(evil +everywhere)/;;(evil +everywhere)/g' ~/.config/doom/init.el
    ~/.config/emacs/bin/doom sync

    echo "Done."
fi # doom emacs setup

if [ "$ENABLE_OMZ_VSCODE" = true ]; then
    sed -i -e 's/#vscode/vscode/g' ~/.zshrc
fi

if [ "$BYOBU_SETUP" = true ]; then
    # Setup byobu status
    mkdir ~/.byobu
    curl -sS https://raw.githubusercontent.com/neboman11/dotfiles/master/.byobu/status -o ~/.byobu/status
    if [ "$ZSH_SETUP" = true ]; then
        byobu-enable
    fi
fi

