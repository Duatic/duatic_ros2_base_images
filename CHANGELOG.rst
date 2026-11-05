^^^^^^^^^
Changelog
^^^^^^^^^

1.3.0 (2026-11-05)
------------------
* feat(factory): prune nightly dev and runtime images after 7 days (#32)
* feat(factory): offer the image build as a composite action (#31)

1.2.0 (2026-11-05)
------------------
* feat(factory): build multi-arch workspace images on a shared ci layer (#29)
* feat(factory): release the dev image with the runtime image (#25)

1.1.0 (2026-11-04)
------------------
* feat(factory): name workspace images for customers (#23)

1.0.4 (2026-11-04)
------------------
* fix(factory): create the release without the gh CLI (#21)

1.0.3 (2026-11-03)
------------------
* fix(factory): push the dev image straight from BuildKit (#19)

1.0.2 (2026-11-03)
------------------
* fix(factory): make GH_PAT optional in nightly and release workflows (#17)

1.0.1 (2026-11-03)
------------------
* fix(factory): default the runners to ubuntu-latest (#15)

1.0.0 (2026-11-03)
------------------
* feat(factory)!: build product images from this repository (#13)

0.1.1 (2026-11-02)
------------------
* fix(ci): skip the Actions cache on releases and tolerate failed cache writes (#11)

0.1.0 (2026-11-02)
------------------
* feat: multi-arch ROS 2 base and dev images (#1)
* Initial commit
