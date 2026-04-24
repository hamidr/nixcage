## Claude Code in a VM-isolated NixOS environment
##
## Usage:
##   1. Copy this file to your project root as nixcage.vm.nix
##   2. Set ANTHROPIC_API_KEY in your host shell
##   3. Run: nixcage init && nixcage build && nixcage shell
##   4. Inside the VM: claude
##
## The API key is injected automatically via nixcage secrets (tmpfs,
## never written to disk). claude-code, git, and nodejs are provided
## by the base layer -- you do not need to declare them here.
{ pkgs, ... }: {
  environment.systemPackages = with pkgs; [
    vim
    ripgrep
    fd
  ];
}
