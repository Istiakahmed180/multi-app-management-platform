import type { Types } from 'mongoose';
import { randomToken } from '../../shared/crypto.js';
import { toObjectId } from '../../shared/db.js';
import { AppError, conflict, forbidden, isDuplicateKeyError, notFound } from '../../shared/errors.js';
import type { AuthContext } from '../../shared/http.js';
import { accessibleAppFilter, resolveTenant } from '../../shared/middleware/tenancy.js';
import { escapeRegex, pageMeta, skip, type PaginationQuery } from '../../shared/pagination.js';
import { AppUser } from '../app-users/app-user.models.js';
import { defaultConfigContent } from '../configurations/config.content.js';
import { AppConfig } from '../configurations/config.model.js';
import { FeatureFlag } from '../feature-flags/feature-flag.model.js';
import { Integration } from '../integrations/integration.model.js';
import { slugify } from '../organizations/organization.schemas.js';
import { App, type AppStatus } from './app.model.js';

export function generateAppKey(): string {
  return `app_${randomToken(15).replace(/[-_]/g, 'x')}`;
}

interface ListQuery extends PaginationQuery {
  orgId?: string;
  search?: string;
  status?: string;
  platform?: string;
  environment?: string;
  sort: Record<string, 1 | -1>;
}

export class AppService {
  async list(auth: AuthContext, q: ListQuery) {
    const access = await accessibleAppFilter(auth, q.orgId ? toObjectId(q.orgId) : undefined);
    if (!access) return { items: [], meta: pageMeta(q, 0) };
    const filter: Record<string, unknown> = { ...access };
    if (q.status) filter.status = q.status;
    else filter.status = { $ne: 'archived' };
    if (q.platform) filter.platforms = q.platform;
    if (q.environment) filter.environment = q.environment;
    if (q.search) {
      const rx = { $regex: escapeRegex(q.search), $options: 'i' };
      filter.$and = [{ $or: [{ name: rx }, { slug: rx }, { androidPackageId: rx }, { iosBundleId: rx }] }];
    }
    const [items, total] = await Promise.all([
      App.find(filter).sort(q.sort).skip(skip(q)).limit(q.pageSize),
      App.countDocuments(filter),
    ]);
    return { items: items.map((a) => a.toJSON()), meta: pageMeta(q, total) };
  }

  async create(
    auth: AuthContext,
    input: {
      orgId: string;
      name: string;
      slug?: string;
      description: string;
      platforms: ('android' | 'ios')[];
      androidPackageId: string | null;
      iosBundleId: string | null;
      environment: 'development' | 'staging' | 'production';
      iconUrl: string | null;
    },
  ) {
    const orgId = toObjectId(input.orgId);
    // The org id comes from the client, so access is verified here before anything is written.
    const tenant = await resolveTenant(auth, orgId);
    if (!tenant) throw notFound('Organization');
    if (!tenant.permissions.has('apps:create')) throw forbidden();
    const slug = input.slug ?? slugify(input.name);
    try {
      const app = await App.create({
        ...input,
        androidPackageId: input.platforms.includes('android') ? input.androidPackageId : null,
        iosBundleId: input.platforms.includes('ios') ? input.iosBundleId : null,
        orgId,
        slug,
        appKey: generateAppKey(),
        createdBy: auth.adminId,
      });
      await AppConfig.create({
        appId: app._id,
        orgId,
        state: 'draft',
        content: defaultConfigContent(app.name),
        updatedBy: auth.adminId,
      });
      return app;
    } catch (err) {
      if (isDuplicateKeyError(err))
        throw conflict('An app with this slug already exists in the organization', { fields: ['slug'] });
      throw err;
    }
  }

  async get(appId: Types.ObjectId) {
    const app = await App.findById(appId);
    if (!app) throw notFound('App');
    const [userCount, flagCount, draft, integrations] = await Promise.all([
      AppUser.countDocuments({ appId }),
      FeatureFlag.countDocuments({ appId }),
      AppConfig.findOne({ appId, state: 'draft' }).select('updatedAt').lean(),
      Integration.find({ appId, status: 'active' }).select('type').lean(),
    ]);
    const types = new Set(integrations.map((i) => i.type));
    return {
      ...app.toJSON(),
      summary: {
        userCount,
        flagCount,
        draftUpdatedAt: draft?.updatedAt ?? null,
        integrations: {
          fcm: types.has('fcm'),
          serverApiKey: types.has('server_api_key'),
          webhook: types.has('webhook'),
        },
      },
    };
  }

  async update(appId: Types.ObjectId, patch: Record<string, unknown>) {
    const app = await App.findById(appId);
    if (!app) throw notFound('App');
    const before = app.toJSON();
    app.set(patch);
    const platforms = app.platforms as string[];
    if (!platforms.includes('android')) app.androidPackageId = null;
    if (!platforms.includes('ios')) app.iosBundleId = null;
    if (platforms.includes('android') && !app.androidPackageId) {
      throw new AppError('validation_failed', 'Request validation failed', [
        { path: 'androidPackageId', message: 'Required when Android is a platform' },
      ]);
    }
    if (platforms.includes('ios') && !app.iosBundleId) {
      throw new AppError('validation_failed', 'Request validation failed', [
        { path: 'iosBundleId', message: 'Required when iOS is a platform' },
      ]);
    }
    try {
      await app.save();
    } catch (err) {
      if (isDuplicateKeyError(err))
        throw conflict('An app with this slug already exists in the organization', { fields: ['slug'] });
      throw err;
    }
    return { app, before };
  }

  async setStatus(appId: Types.ObjectId, status: AppStatus) {
    const app = await App.findById(appId);
    if (!app) throw notFound('App');
    const previous = app.status;
    app.status = status;
    await app.save();
    return { app, previous };
  }
}
