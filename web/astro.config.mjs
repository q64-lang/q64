import { defineConfig } from 'astro/config';
import starlight from '@astrojs/starlight';
import sitemap from '@astrojs/sitemap';

export default defineConfig({
  site: 'https://q64.dev',
  trailingSlash: 'ignore',
  integrations: [
    starlight({
      title: 'q64',
      description: 'A modern toolchain for WebAssembly and beyond.',
      // Search is disabled on the landing site — it has no real content to
      // index. Full docs search lives on docs.q64.dev. Remove this to re-enable.
      pagefind: false,
      social: {
        github: 'https://github.com/q64-lang/q64',
      },
      sidebar: [
        { label: 'Welcome', slug: 'welcome' },
      ],
      customCss: ['./src/styles/custom.css'],
      components: {
        Footer: './src/components/Footer.astro',
      },
      head: [
        {
          tag: 'link',
          attrs: { rel: 'canonical', href: 'https://q64.dev/' },
        },
      ],
    }),
    sitemap(),
  ],
});
