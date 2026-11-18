# Install Odin

```zsh
git clone https://github.com/odin-lang/Odin  && cd Odin/
git checkout dev-2026-11a 
git lfs pull

➜  Odin git:(dev-2026-11a) LLVM_CONFIG=/opt/homebrew/opt/llvm/bin/llvm-config make release-native 

echo 'export PATH="/Users/macbas/odin/Odin:$PATH"' >> ~/.zshrc
source ~/.zshrc
odin version ➜ dev-2026-11:9a6991685
```