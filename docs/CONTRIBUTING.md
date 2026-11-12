---
title: Contributing
nav_order: 2
permalink: /contributing/
---

# Contributing

Indie Dev Buddy is an open-source project. Bug reports, ideas, code changes, and documentation improvements are welcome through GitHub issues and pull requests.

## Suggesting a documentation change

Documentation lives in the repository's `docs/` directory as Markdown source. Update the relevant page in the same pull request as a code or behavior change. For a new page, add a title and `nav_order` in its YAML front matter so the page appears in this site's navigation. Do not commit generated site output.

To preview the site locally, install Ruby 3.3 and Bundler 2.4.22, then run:

```sh
gem install bundler -v 2.4.22
cd docs
bundle install
bundle exec jekyll serve --baseurl ""
```

Open the local URL printed by Jekyll. GitHub Actions builds the site for pull requests to `main`, so contributors and reviewers can catch Jekyll and theme build errors before merge.

If you do not have write access, fork the repository, create a branch, make your changes, and open a pull request against `main`. Describe what changed and link the issue or feature when relevant. Use **Suggest an edit on GitHub** on a documentation page to open the source file in GitHub's editor and start a change from a fork.

For each new page, set `title`, `nav_order`, and a stable `permalink` in the Markdown front matter. Keep internal links pointed at the published page paths, update the relevant pages when app behavior changes, and leave generated `_site/` output uncommitted.

For code changes, explain the user-facing behavior and relevant verification in the pull request. Keep documentation, setup instructions, and capability notes in sync with the code they describe. Never commit credentials, signing keys, or other secrets.
