# Install dein.vim
if [ -e ~/.local/share/nvim/dein ]; then
  echo "dein.vim is already installed."
else
  echo "Install dein.vim to ~/.local/share/nvim."
  curl https://raw.githubusercontent.com/Shougo/dein.vim/master/bin/installer.sh > installer.sh
  sh ./installer.sh ~/.local/share/nvim
  rm ./installer.sh
fi

# Install ripgrep
if type "rg" > /dev/null 2>&1; then
  echo "ripgrep is already installed."
else
  echo "ripgrep not found."
  sudo apt install -y ripgrep
fi

# Install nodejs
if type "node" > /dev/null 2>&1; then
  echo "nodejs is already installed."
else
  echo "nodejs not found."
  curl -fsSL https://deb.nodesource.com/setup_lts.x | sudo -E bash -
  sudo apt-get install -y nodejs
fi



