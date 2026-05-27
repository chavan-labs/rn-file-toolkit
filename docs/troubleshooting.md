# Troubleshooting

## Docs site not updating

- Confirm the docs workflow passed
- Confirm GitHub Pages source is set to **GitHub Actions**
- Check repository is public (or Pages enabled for private repo plan)

## 404 on docs URL

Use this URL format:

`https://<org-or-user>.github.io/<repo>/`

For this repo:

`https://chavan-labs.github.io/rn-file-toolkit/`

## Expo issue

Expo Go is not supported for native modules. Use a custom dev client or EAS build.
