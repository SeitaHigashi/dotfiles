#!/bin/bash

# Setting the text format.
installed="\e[32minstalled\e[m"
not_found="\e[31mnot found\e[m"

# Install neovim
if type "nvim" > /dev/null 2>&1; then
  echo -e "neovim is already $installed."
else
  echo -e "neovim is $not_found."
  echo -e "Please install neovim."
fi

# Install git
if type "git" > /dev/null 2>&1; then
  echo -e "git is already $installed."
else
  echo -e "git is $not_found."
  echo -e "Please install git."
  exit 1
fi

packer_dir="$HOME/.local/share/nvim/site/pack/packer/start/packer.nvim"

echo -e "checking packer that is plugin manager for neovim..."
if [ ! -d $packer_dir ]; then
  echo -e "packer is $not_found."
  echo -e "try to install packer.nvim"
  git clone --depth 1 https://github.com/wbthomason/packer.nvim $packer_dir
else
  echo -e "packer is already $installed."
fi

# Install ripgrep
if type "rg" > /dev/null 2>&1; then
  echo -e "ripgrep is already $installed."
else
  echo -e "ripgrep is $not_found."
  echo -e "Please install ripgrep."
fi

# Install nodejs
if type "node" > /dev/null 2>&1; then
  echo -e "nodejs is already $installed."
else
  echo -e "nodejs is $not_found."
  echo -e "Please install nodejs."
fi



