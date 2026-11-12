---
title: patchy-app-manifests
template: home.html
hide:
  - navigation
  - toc
---

<!--
  The home page is rendered entirely by overrides/home.html (the landing).
  This body only provides the page title and meta description for the <head>.
-->

patchy as an application image for the platform clusters: a cosign-signed OCI artifact holding everything patchy deploys
on a cluster, whose builds terraform picks on every apply and flux deploys, plus the per-cloud terraform modules that
install it.
