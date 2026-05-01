import 'dotenv/config';
import { PrismaClient } from '@prisma/client';

const prisma = new PrismaClient();

async function main() {
  console.log('Sembrando datos del sistema...');

  // ── Temas del sistema ──────────────────────────────────────────────────────
  const themes = [
    {
      name: 'Default', isSystemDefault: true, isActive: false,
      primaryColor: '#000000', secondaryColor: '#ffffff', fontFamily: 'DM Sans',
      borderRadius: '0.75rem', darkMode: false,
    },
    {
      name: 'Dark', isSystemDefault: true, isActive: false,
      primaryColor: '#ffffff', secondaryColor: '#0a0a0a', fontFamily: 'DM Sans',
      borderRadius: '0.75rem', darkMode: true,
    },
    {
      name: 'Minimal', isSystemDefault: true, isActive: false,
      primaryColor: '#1a1a1a', secondaryColor: '#fafafa', fontFamily: 'Inter',
      borderRadius: '0.25rem', darkMode: false,
    },
    {
      name: 'Bold', isSystemDefault: true, isActive: false,
      primaryColor: '#4F46E5', secondaryColor: '#EEF2FF', fontFamily: 'Poppins',
      borderRadius: '1rem', darkMode: false,
    },
  ];

  for (const theme of themes) {
    await prisma.themeConfig.upsert({
      where:  { organizationId_name: { organizationId: null as any, name: theme.name } },
      update: theme,
      create: theme,
    });
  }
  console.log(`✓ ${themes.length} temas del sistema`);

  // ── Plantillas del sistema ─────────────────────────────────────────────────
  const templates = [
    {
      key: 'welcome_email', name: 'Email de bienvenida',
      category: 'email', systemTarget: 'all', isSystemDefault: true,
      content: 'Hola {{nombre}}, bienvenido a {{organizacion}}. Tu cuenta está lista.',
      variables: ['nombre', 'organizacion'],
    },
    {
      key: 'invitation_email', name: 'Email de invitación',
      category: 'email', systemTarget: 'all', isSystemDefault: true,
      content: 'Hola {{nombre}}, {{invitador}} te invita a unirte a {{organizacion}}. Aceptá la invitación aquí: {{link}}',
      variables: ['nombre', 'invitador', 'organizacion', 'link'],
    },
    {
      key: 'chat_welcome_message', name: 'Mensaje de bienvenida del chat',
      category: 'chat', systemTarget: 'chat', isSystemDefault: true,
      content: '¡Hola {{nombre}}! Soy el asistente de {{organizacion}}. ¿En qué puedo ayudarte?',
      variables: ['nombre', 'organizacion'],
    },
    {
      key: 'notification_new_member', name: 'Notificación nuevo miembro',
      category: 'notification', systemTarget: 'all', isSystemDefault: true,
      content: '{{nombre}} se unió a {{organizacion}} con el rol {{rol}}.',
      variables: ['nombre', 'organizacion', 'rol'],
    },
  ];

  for (const tmpl of templates) {
    await prisma.contentTemplate.upsert({
      where:  { organizationId_key: { organizationId: null as any, key: tmpl.key } },
      update: tmpl,
      create: tmpl,
    });
  }
  console.log(`✓ ${templates.length} plantillas del sistema`);

  // ── Feature flags globales ─────────────────────────────────────────────────
  const flags = [
    { key: 'chat_enabled',        enabled: false, description: 'Habilita el módulo de chat',               systemTarget: 'chat'     },
    { key: 'payments_enabled',    enabled: false, description: 'Habilita el módulo de pagos',              systemTarget: 'payments' },
    { key: 'ads_enabled',         enabled: false, description: 'Habilita el módulo de publicidad',         systemTarget: 'ads'      },
    { key: 'webhooks_enabled',    enabled: true,  description: 'Habilita webhooks outbound',               systemTarget: 'all'      },
    { key: 'audit_log_enabled',   enabled: true,  description: 'Habilita el log de auditoría',             systemTarget: 'all'      },
    { key: 'quota_enforcement',   enabled: true,  description: 'Enforce de quotas en todos los sistemas',  systemTarget: 'all'      },
  ];

  for (const flag of flags) {
    await prisma.featureFlag.upsert({
      where:  { organizationId_key: { organizationId: null as any, key: flag.key } },
      update: flag,
      create: flag,
    });
  }
  console.log(`✓ ${flags.length} feature flags globales`);

  console.log('Seed completado.');
}

main()
  .catch((e) => { console.error(e); process.exit(1); })
  .finally(() => prisma.$disconnect());
