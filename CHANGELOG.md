# Changelog

## 0.1.0 (2026-11-12)


### ⚠ BREAKING CHANGES

* modules/aws and modules/google replace manifests_semver with image = { semver, channel }, and no longer publish PATCHY_MANIFESTS_SEMVER or SIGNED_IDENTITY_PATCHY_MANIFESTS. The image's trees move from ./deploy/<tree> to ./<tree>, so a cluster on this module version needs an image built from this commit or later: apply only after its edge build is published.
* releases are tagged vX.Y.Z (promoted edge builds) instead of X.Y.Z, the edge/staging/stable/edge-next tags are gone, and the default signed_identity_subject is now release.yaml@refs/heads/main: re-apply the modules so clusters verify the new identity before the first release under this version.

### Features

* **aws:** create_secrets toggle to grant on existing containers ([2ac12c1](https://github.com/bitwise-media-group/patchy-app-manifests/commit/2ac12c1c45b1d5d3fbc9fa83db6ca40ca2224d79))
* **google:** create_secrets toggle to grant on existing containers ([caf8064](https://github.com/bitwise-media-group/patchy-app-manifests/commit/caf8064ada74d5eaa886127d3439a3366af20c6f))
* install patchy as a self-contained application image ([fc20652](https://github.com/bitwise-media-group/patchy-app-manifests/commit/fc2065284f354d1cd9f57853e73fabc310435e17))
* let terraform own the seed and flatten the image to manifests/&lt;tree&gt; ([cfe8179](https://github.com/bitwise-media-group/patchy-app-manifests/commit/cfe817909a558e6ea1a074c82dbc681f4742d9d0))
* **policy:** migrate image verification to Kyverno's CEL kinds ([cd3c530](https://github.com/bitwise-media-group/patchy-app-manifests/commit/cd3c5309998f461f13a3b9e6cedb355161dfe60a))
* publish immutable edge builds and promote releases from the release pipeline ([311c2dc](https://github.com/bitwise-media-group/patchy-app-manifests/commit/311c2dca23d5a1eccd45dcd3de639d077d3150c7))


### Bug Fixes

* **deps:** pin terraform-google-gke-flux d74b532 and terraform-aws-eks-flux b1aa85c ([2dfb5f9](https://github.com/bitwise-media-group/patchy-app-manifests/commit/2dfb5f93e7b06f8efe1a81ea0f1c3ff828a9d186))
* **deps:** pin terraform-google-gke-flux modules/application to ddc4be2 ([23b1820](https://github.com/bitwise-media-group/patchy-app-manifests/commit/23b1820f5daf1072364d7d4d5fa1eb08bd9fb598))
* **deps:** update bitwise-media-group/github-workflows action to v8.1.0 ([#16](https://github.com/bitwise-media-group/patchy-app-manifests/issues/16)) ([9d139da](https://github.com/bitwise-media-group/patchy-app-manifests/commit/9d139da7361bb153c633075fae9159181d3feeab))
* **deps:** update bitwise-media-group/github-workflows action to v8.1.1 ([#20](https://github.com/bitwise-media-group/patchy-app-manifests/issues/20)) ([351a412](https://github.com/bitwise-media-group/patchy-app-manifests/commit/351a4129eb42c7a31726bdd87b67dfdcc274539c))
* **deps:** update bitwise-media-group/github-workflows action to v8.3.0 ([#30](https://github.com/bitwise-media-group/patchy-app-manifests/issues/30)) ([a9f7d41](https://github.com/bitwise-media-group/patchy-app-manifests/commit/a9f7d4110241cbc9be8f26db360cda030c72d358))
* **deps:** update fluxcd/flux2 action to v2.10.0 ([#11](https://github.com/bitwise-media-group/patchy-app-manifests/issues/11)) ([a154fde](https://github.com/bitwise-media-group/patchy-app-manifests/commit/a154fdefc49ae5fbcf648dec4c595cc0b230fb18))
* **deps:** update sigstore/cosign-installer action to v4.1.3 ([#25](https://github.com/bitwise-media-group/patchy-app-manifests/issues/25)) ([ec0feaf](https://github.com/bitwise-media-group/patchy-app-manifests/commit/ec0feafc90410f0482e7fe54583940a3b23a52e2))
* **dex:** compare the evaluation input as a string whatever its YAML type ([3888b4a](https://github.com/bitwise-media-group/patchy-app-manifests/commit/3888b4a6a75c5bcec8ff550e945b507a7136c79d))
* **modules:** pin upper bound to &lt; major ([fbc50f3](https://github.com/bitwise-media-group/patchy-app-manifests/commit/fbc50f3beb16c3bf0d30eca404d513c04e65c67d))
* **publish:** pre-create pull dirs and quieten cosign signing ([d404234](https://github.com/bitwise-media-group/patchy-app-manifests/commit/d4042348fc45598bba5ea3e1a970e531350168a3))
* **release:** start the first release at 0.1.0 ([fa394f6](https://github.com/bitwise-media-group/patchy-app-manifests/commit/fa394f6828a34387fa22723b51564c3fe73cdf47))
