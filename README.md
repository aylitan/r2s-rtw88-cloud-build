# iStoreOS R2S RTL8822BU permanent-fix cloud build

This repository builds only the kernel/mac80211 pieces needed for the R2S RTL8822BU fix. It does not install anything on the R2S.

Locked inputs:

- iStoreOS commit: `72437fb255349cb13e524298b1b6040f83a00562`
- mac80211/backports: `6.12.61-r2`
- kernel dependency: `6.6.141~77d4782035a23e6f19f9c4751451b4e3-r1`
- architecture: `aarch64_generic`
- patch commit: `f24d0d8c3cd7`

The workflow fails closed. It uploads installable packages only when all four IPKs have the expected version, architecture and exact kernel ABI dependency, and all four modules have the expected `vermagic`.

## Run

Open **Actions** -> **Build patched rtw88 for iStoreOS R2S** -> **Run workflow**.

On success, download artifact:

`r2s-rtw88-patched-6.6.141-r2`

Do not install it manually yet. The next stage creates an R2S-side backup, installation, validation and automatic rollback script.
