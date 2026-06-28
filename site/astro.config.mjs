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
      // Explicit sidebar: setting this turns off Starlight's auto-generation
      // for the whole site, so every group the nav shows is listed here. Only
      // pages that exist are linked — a link to a missing page would emit a
      // build warning.
      sidebar: [
        {
          label: 'Start Here',
          items: [
            { label: 'Overview', link: '/start/overview/' },
          ],
        },
        {
          label: 'Concepts',
          items: [
            { label: 'Architecture', link: '/concepts/architecture/' },
            { label: 'Steps', link: '/concepts/steps/' },
            { label: 'Tools', link: '/concepts/tools/' },
            { label: 'Actors', link: '/concepts/actors/' },
            { label: 'Decision layer', link: '/concepts/decision-layer/' },
            { label: 'Events and trace', link: '/concepts/events-and-trace/' },
            { label: 'Durability', link: '/concepts/durability/' },
            { label: 'Resume', link: '/concepts/resume/' },
          ],
        },
        {
          label: 'Guides',
          items: [
            { label: 'Usage', link: '/guides/usage/' },
            { label: 'LFE DSL', link: '/guides/lfe-dsl/' },
            { label: 'CLI', link: '/guides/cli/' },
            { label: 'Release', link: '/guides/release/' },
          ],
        },
        {
          label: 'Reference',
          items: [
            { label: 'Roadmap', link: '/reference/roadmap/' },
          ],
        },
      ],
    }),
  ],
});
