#!/bin/bash

# This script sets up the home directory with the config files set the way I like them.
# It sets the .zshrc file, installs some zsh plugins, installs doom emacs, and sets evil to default to emacs mode.
# THIS SCRIPT REQUIRES ZSH AND EMACS TO BE INSTALLED BEFORE IT IS RUN.

# Parsing variables
DOOM_EMACS=true
ZSH_SETUP=true
i3_SETUP=false

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
    echo "  Do not setup i3."
}

# Parse command line options using getopts
while getopts "h?dzi" opt; do
    case "$opt" in
    h|\?)
        show_help
        exit 0
        ;;
    d)  DOOM_EMACS=false
        ;;
    z)  ZSH_SETUP=false
        ;;
    i)  i3_SETUP=true
        ;;
    esac
done

if [ "$ZSH_SETUP" = true ]; then
    # Install oh-my-zsh
    sh -c "$(curl -fsSL https://raw.githubusercontent.com/ohmyzsh/ohmyzsh/master/tools/install.sh)"

    # Download .zshrc and .p10k.zsh from this repo
    echo "Downloading .zshrc and .p10k.zsh..."
    curl -sS https://raw.githubusercontent.com/neboman11/dotfiles/master/.zshrc -o ~/.zshrc
    curl -sS https://raw.githubusercontent.com/neboman11/dotfiles/master/.p10k.zsh -o ~/.p10k.zsh

    # Download the zsh plugins and themes and place them in the oh my zsh folder
    echo "Downloading zsh plugins and themes..."
    git clone --depth 1 https://github.com/zsh-users/zsh-autosuggestions.git ${ZSH_CUSTOM:-~/.oh-my-zsh/custom}/plugins/zsh-autosuggestions
    git clone --depth 1 https://github.com/ChesterYue/ohmyzsh-theme-passion.git ${ZSH_CUSTOM:-~/.oh-my-zsh/custom}/themes/passion
    git clone --depth 1 https://github.com/Moarram/headline.git ${ZSH_CUSTOM:-~/.oh-my-zsh/custom}/themes/headline
    git clone --depth=1 https://github.com/romkatv/powerlevel10k.git ${ZSH_CUSTOM:-$HOME/.oh-my-zsh/custom}/themes/powerlevel10k

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

if [ "$DOOM_EMACS" = true ]; then
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

if [ "$i3_SETUP" = true ]; then
    # Copy i3 config files and xserver config files
    echo "Fetching i3 config..."
    mkdir -p ~/.i3
    curl https://raw.githubusercontent.com/neboman11/dotfiles/master/.i3/config -o ~/.i3/config
fi
