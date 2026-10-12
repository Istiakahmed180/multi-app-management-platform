import { z } from 'zod';

const hexColor = z.string().regex(/^#[0-9a-fA-F]{6}([0-9a-fA-F]{2})?$/, 'Must be a hex color like #1A73E8');
const httpsUrl = z
  .string()
  .url()
  .max(2048)
  .refine((u) => /^https:\/\//i.test(u), 'Must be an https URL');
const semver = z.string().regex(/^\d+\.\d+\.\d+(?:[-+][0-9A-Za-z.-]+)?$/, 'Must be a semantic version like 1.4.0');
const key = z.string().regex(/^[a-z][a-z0-9_.-]{0,63}$/, 'Lowercase key: letters, digits, _ . -');

const palette = z
  .object({
    primary: hexColor,
    secondary: hexColor,
    background: hexColor,
    surface: hexColor,
    error: hexColor,
  })
  .strict();

const platformPolicy = z
  .object({
    minimumVersion: semver.nullable(),
    latestVersion: semver.nullable(),
    updateUrl: httpsUrl.nullable(),
  })
  .strict();

const banner = z
  .object({
    id: key,
    title: z.string().min(1).max(120),
    subtitle: z.string().max(240).nullable().default(null),
    imageUrl: httpsUrl.nullable().default(null),
    actionUrl: z.string().max(2048).nullable().default(null),
    active: z.boolean().default(true),
    priority: z.number().int().min(0).max(1000).default(0),
    startsAt: z.iso.datetime().nullable().default(null),
    endsAt: z.iso.datetime().nullable().default(null),
  })
  .strict();

const onboardingPage = z
  .object({
    title: z.string().min(1).max(120),
    body: z.string().max(600),
    imageUrl: httpsUrl.nullable().default(null),
  })
  .strict();

/**
 * Full configuration document edited in the dashboard.
 * Only fields listed in `toPublicConfig` are ever sent to client apps.
 */
export const configContentSchema = z
  .object({
    branding: z
      .object({
        appTitle: z.string().min(1).max(80),
        logoUrl: httpsUrl.nullable(),
      })
      .strict(),
    theme: z
      .object({
        defaultMode: z.enum(['system', 'light', 'dark']),
        darkModeEnabled: z.boolean(),
        light: palette,
        dark: palette,
      })
      .strict(),
    maintenance: z
      .object({
        enabled: z.boolean(),
        title: z.string().max(120),
        message: z.string().max(1000),
        estimatedEndAt: z.iso.datetime().nullable(),
      })
      .strict(),
    updatePolicy: z
      .object({
        android: platformPolicy,
        ios: platformPolicy,
        message: z.string().max(500),
      })
      .strict(),
    banners: z
      .array(banner)
      .max(20)
      .refine((b) => new Set(b.map((x) => x.id)).size === b.length, 'Banner ids must be unique'),
    onboarding: z
      .object({
        enabled: z.boolean(),
        pages: z.array(onboardingPage).max(10),
      })
      .strict(),
    // Free-form copy for screens the app already implements (e.g. "home.welcome").
    strings: z.record(key, z.string().max(1000)).refine((r) => Object.keys(r).length <= 200, 'At most 200 strings'),
    // Visible only in the dashboard. Never exposed publicly.
    internalNotes: z.string().max(5000),
  })
  .strict();

export type ConfigContent = z.infer<typeof configContentSchema>;

export function defaultConfigContent(appName: string): ConfigContent {
  return {
    branding: { appTitle: appName.slice(0, 80), logoUrl: null },
    theme: {
      defaultMode: 'system',
      darkModeEnabled: true,
      light: { primary: '#2563EB', secondary: '#7C3AED', background: '#FFFFFF', surface: '#F8FAFC', error: '#DC2626' },
      dark: { primary: '#60A5FA', secondary: '#A78BFA', background: '#0B1120', surface: '#111827', error: '#F87171' },
    },
    maintenance: { enabled: false, title: '', message: '', estimatedEndAt: null },
    updatePolicy: {
      android: { minimumVersion: null, latestVersion: null, updateUrl: null },
      ios: { minimumVersion: null, latestVersion: null, updateUrl: null },
      message: '',
    },
    banners: [],
    onboarding: { enabled: false, pages: [] },
    strings: {},
    internalNotes: '',
  };
}

/** Explicit allow-list projection for the public, unauthenticated endpoint. */
export function toPublicConfig(c: ConfigContent, now = new Date()) {
  const visibleBanners = c.banners
    // Future banners are kept (the SDK checks the time window) so cached config stays useful offline.
    .filter((b) => b.active)
    .filter((b) => !b.endsAt || new Date(b.endsAt) > now)
    .sort((a, b) => b.priority - a.priority)
    .map((b) => ({
      id: b.id,
      title: b.title,
      subtitle: b.subtitle,
      imageUrl: b.imageUrl,
      actionUrl: b.actionUrl,
      priority: b.priority,
      startsAt: b.startsAt,
      endsAt: b.endsAt,
    }));
  return {
    branding: { appTitle: c.branding.appTitle, logoUrl: c.branding.logoUrl },
    theme: {
      defaultMode: c.theme.defaultMode,
      darkModeEnabled: c.theme.darkModeEnabled,
      light: { ...c.theme.light },
      dark: { ...c.theme.dark },
    },
    maintenance: {
      enabled: c.maintenance.enabled,
      title: c.maintenance.title,
      message: c.maintenance.message,
      estimatedEndAt: c.maintenance.estimatedEndAt,
    },
    updatePolicy: {
      android: { ...c.updatePolicy.android },
      ios: { ...c.updatePolicy.ios },
      message: c.updatePolicy.message,
    },
    banners: visibleBanners,
    onboarding: {
      enabled: c.onboarding.enabled,
      pages: c.onboarding.pages.map((p) => ({ title: p.title, body: p.body, imageUrl: p.imageUrl })),
    },
    strings: { ...c.strings },
  };
}

export { semver as semverSchema, httpsUrl as httpsUrlSchema, key as keySchema };
