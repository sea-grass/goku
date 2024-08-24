FROM ubuntu:20.04

ARG USERNAME=vimwiki

RUN apt-get update; \
  apt-get install -y git neovim curl && \
  apt-get autoremove -y && \
  apt-get autoclean -y && \
  useradd -m -s /bin/bash $USERNAME && \
  usermod -aG sudo $USERNAME && \
  echo vimwiki-builder > /etc/hostname

WORKDIR /home/$USERNAME
USER $USERNAME

RUN sh -c 'curl -fLo "${XDG_DATA_HOME:-$HOME/.local/share}"/nvim/site/autoload/plug.vim --create-dirs https://raw.githubusercontent.com/junegunn/vim-plug/master/plug.vim'
COPY config/init.vim /home/$USERNAME/.config/nvim/init.vim

deps:
  RUN nvim --headless +PlugInstall +qall >/dev/null

build:
  FROM +deps
  COPY wiki wiki 
  RUN nvim --headless +VimwikiIndex +VimwikiAll2HTML +qall >/dev/null
  SAVE ARTIFACT /home/$USERNAME/build AS LOCAL build
