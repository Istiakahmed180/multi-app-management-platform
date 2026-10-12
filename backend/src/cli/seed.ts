/**
 * Development-only seed: creates a super admin and an example organization.
 * Credentials come from SEED_ADMIN_EMAIL / SEED_ADMIN_PASSWORD; nothing is hardcoded.
 */
import { loadEnv } from '../config/env.js';
import { Admin } from '../modules/auth/auth.models.js';
import { Membership, Organization } from '../modules/organizations/organization.models.js';
import { hashPassword } from '../shared/crypto.js';
import { connectDatabase, disconnectDatabase } from '../shared/db.js';

async function main() {
  const env = loadEnv();
  if (env.NODE_ENV === 'production' || env.NODE_ENV === 'staging') {
    throw new Error('The seed script is for development only. Refusing to run in ' + env.NODE_ENV);
  }
  const email = process.env.SEED_ADMIN_EMAIL?.trim().toLowerCase();
  const password = process.env.SEED_ADMIN_PASSWORD;
  if (!email || !password) throw new Error('Set SEED_ADMIN_EMAIL and SEED_ADMIN_PASSWORD');
  if (password.length < 12) throw new Error('SEED_ADMIN_PASSWORD must be at least 12 characters');

  await connectDatabase(env.MONGODB_URI);
  await Promise.all([Admin.syncIndexes(), Organization.syncIndexes(), Membership.syncIndexes()]);

  let admin = await Admin.findOne({ email });
  if (admin) {
    console.log(`Admin ${email} already exists; leaving it unchanged.`);
  } else {
    admin = await Admin.create({ email, name: 'Platform Admin', passwordHash: await hashPassword(password), isSuperAdmin: true });
    console.log(`Created super admin ${email}`);
  }

  const orgName = process.env.SEED_ORG_NAME ?? 'Development Org';
  let org = await Organization.findOne({ slug: 'development-org' });
  if (!org) {
    org = await Organization.create({ name: orgName, slug: 'development-org', createdBy: admin._id });
    console.log(`Created organization "${org.name}"`);
  }
  await Membership.updateOne(
    { orgId: org._id, adminId: admin._id },
    { $setOnInsert: { role: 'owner', createdBy: admin._id } },
    { upsert: true },
  );
  await disconnectDatabase();
}

main().catch(async (err) => {
  console.error(err instanceof Error ? err.message : err);
  await disconnectDatabase().catch(() => undefined);
  process.exit(1);
});
