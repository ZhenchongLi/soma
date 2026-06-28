// @ts-check
import { defineConfig } from 'astro/config';
import starlight from '@astrojs/starlight';

// Directory-format output so every route lands as <route>/index.html.
export default defineConfig({
  // Canonical site URL (used by the bundled sitemap integration).
  site: 'https://soma.fists.cc',
  build: {
    format: 'directory',
  },
  integrations: [
    starlight({
      title: 'Soma',
      // English-only site — no i18n locales configured.
      customCss: ['./src/styles/custom.css'],
    }),
  ],
});
