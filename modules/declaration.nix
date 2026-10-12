## The declaration a host renders (ADR-024), as one text for both modules, so
## a key the reader in declaration.sh learns is rendered in one place. What
## only one platform has comes in as `extra`; the reader sources the file,
## so where a line falls does not matter to it.
{ lib }:
{
  cfg,
  platform,
  ## Checked by the module first: a root with a colon is refused there.
  workspaceRoots,
  storageDataset,
  extra ? "",
}:
''
  DECLARATION_VERSION=1
  HOST_PLATFORM=${platform}
  WORKSPACE_ROOTS=${lib.concatStringsSep ":" workspaceRoots}
  ${cfg.boundsConfigText}${lib.optionalString (cfg.principalUidRange != null) ''
    PRINCIPAL_UID_BASE=${toString cfg.principalUidRange.base}
    PRINCIPAL_UID_SIZE=${toString cfg.principalUidRange.size}
  ''}PRINCIPAL_SUBJECTS="${lib.concatStringsSep " " cfg.principalSubjects}"
  STORAGE_DATASET=${storageDataset}
  SECRET_ENV="${
    lib.concatStringsSep " " (lib.mapAttrsToList (var: secret: "${var}=${secret}") cfg.secretEnv)
  }"
  ${lib.optionalString (cfg.git.userName != null) ''
    GIT_USER_NAME="${cfg.git.userName}"
  ''}${lib.optionalString (cfg.git.userEmail != null) ''
    GIT_USER_EMAIL="${cfg.git.userEmail}"
  ''}GIT_SIGNING=${if cfg.git.signing.enable then "1" else ""}
  ${extra}''
