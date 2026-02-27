import { defineConfig } from 'wxt';

// See https://wxt.dev/api/config.html
export default defineConfig({
  srcDir: 'src',
  modules: ['@wxt-dev/module-svelte'],
  manifest: {
    name: 'NewDownloadManager',
    description: 'Intercept browser downloads and forward them to NewDownloadManager on macOS.',
    permissions: ['downloads', 'storage', 'tabs', 'notifications'],
    host_permissions: ['<all_urls>', 'http://127.0.0.1/*'],
    action: {
      default_title: 'NewDownloadManager',
    },
  },
});
