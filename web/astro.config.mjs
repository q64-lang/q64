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
