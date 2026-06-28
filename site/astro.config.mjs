// @ts-check
import { defineConfig } from 'astro/config';
import starlight from '@astrojs/starlight';

// Directory-format output so every route lands as <route>/index.html.
// The acceptance criteria name paths like start/overview/index.html, which is
// what directory format produces.
export default defineConfig({
  // A canonical site URL. Set so the bundled sitemap integration has a base and
  // the build emits no sitemap warning. Adjust when the real domain is known.
  site: 'https://soma.example',
  build: {
    format: 'directory',
  },
  integrations: [
    starlight({
      title: 'Soma',
      // English at the root, 简体中文 under /zh/. More than one locale makes
      // Starlight render its built-in language picker.
      defaultLocale: 'root',
      locales: {
        root: {
          label: 'English',
          lang: 'en',
        },
        zh: {
          label: '简体中文',
          lang: 'zh-CN',
        },
      },
      customCss: ['./src/styles/custom.css'],
    }),
  ],
});
