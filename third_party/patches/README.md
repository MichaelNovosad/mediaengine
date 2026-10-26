# Patches

Our changes to the third-party sources, as unified diffs (`*.diff`, applied in file-name order by the build scripts, listed
in `BUILD-INFO.txt` and shipped in the source pack). **There are none**: every binary is built from the unmodified,
signature- and SHA-256-checked upstream archives named in `../sources.lock`. Anything added here must be a diff against
exactly that archive, and the build scripts must apply it (the source pack check fails on a diff that is not applied).
