/*
 * autobrightness: automatic screen brightness with a logarithmic curve and
 * gradual changes.
 *
 * Follows the ambient light sensor (iio-sensor-proxy) through a low-pass
 * filter on log(lux), maps it to a brightness on a perceptual curve, and moves
 * the backlight (gsd-power) one percent at a time. When the brightness is
 * changed by hand, the curve shifts so that the chosen brightness becomes the
 * one for the current light; the shift is kept across sessions. gsd-power's
 * own ambient mode (ambient-enabled) has to be off, or both drive the
 * backlight.
 *
 * Runs in the desktop session (XDG autostart): iio-sensor-proxy hands the
 * light sensor only to processes of the active session.
 */

#include <gio/gio.h>
#include <glib-unix.h>
#include <math.h>
#include <stdio.h>

#define LUX_FULL 3000.0   /* light level that maps to full brightness */
#define GAMMA 2.2         /* perceived brightness to backlight level */
#define MIN_PCT 1
#define TAU 4.0           /* seconds; time constant of the low-pass filter */
#define TICK_MS 60        /* one-percent step while changing */
#define DEADBAND 0.04     /* perceived difference that starts a change */
#define IDLE_DIM_MS 10000 /* a change from outside after this much idle time is gsd-power dimming */

#define SENSOR_BUS "net.hadess.SensorProxy"
#define SENSOR_PATH "/net/hadess/SensorProxy"
#define POWER_BUS "org.gnome.SettingsDaemon.Power"
#define POWER_PATH "/org/gnome/SettingsDaemon/Power"
#define SCREEN_IFACE "org.gnome.SettingsDaemon.Power.Screen"
#define IDLE_BUS "org.gnome.Mutter.IdleMonitor"
#define IDLE_PATH "/org/gnome/Mutter/IdleMonitor/Core"

typedef struct {
  GDBusConnection *system, *session;
  GDBusProxy *sensor, *screen;
  gboolean have_light, have_bias;
  double light, level, bias; /* perceived, 0..1 */
  int current;               /* percent; -1 until known */
  GArray *written;           /* values set but not yet echoed back */
  gboolean dimmed, fading;
  gint64 last_tick;
  guint tick_id;
  char *state_file;
} App;

static double
perceived (double lux)
{
  return MIN (1.0, log10 (1.0 + MAX (0.0, lux)) / log10 (1.0 + LUX_FULL));
}

static int
to_pct (double p)
{
  p = CLAMP (p, 0.0, 1.0);
  return (int) lround (MIN_PCT + (100 - MIN_PCT) * pow (p, GAMMA));
}

static double
from_pct (int pct)
{
  return pow (MAX (0, pct - MIN_PCT) / (double) (100 - MIN_PCT), 1.0 / GAMMA);
}

/* --- state ------------------------------------------------------------ */

static void
load_bias (App *app)
{
  g_autofree char *text = NULL;

  if (g_file_get_contents (app->state_file, &text, NULL, NULL) &&
      sscanf (text, "{\"bias\": %lf}", &app->bias) == 1)
    app->have_bias = TRUE;
}

static void
save_bias (App *app)
{
  g_autofree char *dir = g_path_get_dirname (app->state_file);
  char text[G_ASCII_DTOSTR_BUF_SIZE + 16];
  char num[G_ASCII_DTOSTR_BUF_SIZE];

  g_mkdir_with_parents (dir, 0700);
  g_snprintf (text, sizeof text, "{\"bias\": %s}",
              g_ascii_dtostr (num, sizeof num, app->bias));
  g_file_set_contents (app->state_file, text, -1, NULL);
}

/* --- control loop ------------------------------------------------------ */

static void
set_brightness (App *app, int pct)
{
  app->current = pct;
  g_array_append_val (app->written, pct);
  g_dbus_proxy_call (app->screen, "org.freedesktop.DBus.Properties.Set",
                     g_variant_new ("(ssv)", SCREEN_IFACE, "Brightness",
                                    g_variant_new_int32 (pct)),
                     G_DBUS_CALL_FLAGS_NONE, -1, NULL, NULL, NULL);
}

static gboolean
stop_ticking (App *app)
{
  app->tick_id = 0;
  return G_SOURCE_REMOVE;
}

static gboolean
tick (gpointer data)
{
  App *app = data;
  gint64 now = g_get_monotonic_time ();
  double dt = (now - app->last_tick) / (double) G_USEC_PER_SEC;
  double goal;
  gboolean settled;
  int target;

  app->last_tick = now;
  if (!app->have_light || app->screen == NULL || app->current < 0 || app->dimmed)
    return stop_ticking (app);
  if (!app->have_bias) {
    /* First run: keep the brightness the session started with. */
    app->bias = from_pct (app->current) - app->level;
    app->have_bias = TRUE;
    save_bias (app);
  }
  app->level += (app->light - app->level) * dt / (TAU + dt);
  settled = fabs (app->light - app->level) < 0.005;
  goal = app->level + app->bias;
  target = to_pct (goal);
  /* The deadband only decides whether to start; once moving, follow the
   * filter until it settles. */
  if (!app->fading && fabs (from_pct (app->current) - goal) > DEADBAND)
    app->fading = TRUE;
  if (app->fading && target != app->current) {
    set_brightness (app, app->current + (target > app->current ? 1 : -1));
    return G_SOURCE_CONTINUE;
  }
  if (settled) {
    app->fading = FALSE;
    return stop_ticking (app);
  }
  return G_SOURCE_CONTINUE;
}

static void
start_ticking (App *app)
{
  if (app->tick_id == 0) {
    app->last_tick = g_get_monotonic_time ();
    app->tick_id = g_timeout_add (TICK_MS, tick, app);
  }
}

/* --- light sensor ------------------------------------------------------ */

static void
read_light (App *app)
{
  g_autoptr (GVariant) value = g_dbus_proxy_get_cached_property (app->sensor, "LightLevel");

  if (value == NULL)
    return;
  app->light = perceived (g_variant_get_double (value));
  if (!app->have_light)
    app->level = app->light;
  app->have_light = TRUE;
  start_ticking (app);
}

static void
on_sensor_changed (GDBusProxy *proxy, GVariant *changed, GStrv invalidated, gpointer data)
{
  g_autoptr (GVariant) value = g_variant_lookup_value (changed, "LightLevel", NULL);

  if (value != NULL)
    read_light (data);
}

static void
on_sensor_appeared (GDBusConnection *conn, const char *name, const char *owner, gpointer data)
{
  App *app = data;
  g_autoptr (GVariant) has = NULL;
  g_autoptr (GVariant) reply = NULL;

  app->sensor = g_dbus_proxy_new_sync (conn, G_DBUS_PROXY_FLAGS_NONE, NULL,
                                       SENSOR_BUS, SENSOR_PATH, SENSOR_BUS, NULL, NULL);
  if (app->sensor == NULL)
    return;
  has = g_dbus_proxy_get_cached_property (app->sensor, "HasAmbientLight");
  reply = has && g_variant_get_boolean (has)
    ? g_dbus_proxy_call_sync (app->sensor, "ClaimLight", NULL, G_DBUS_CALL_FLAGS_NONE,
                              -1, NULL, NULL)
    : NULL;
  if (reply == NULL) {
    g_clear_object (&app->sensor);
    return;
  }
  g_signal_connect (app->sensor, "g-properties-changed", G_CALLBACK (on_sensor_changed), app);
  read_light (app);
}

static void
on_sensor_vanished (GDBusConnection *conn, const char *name, gpointer data)
{
  App *app = data;

  g_clear_object (&app->sensor);
}

/* --- backlight (gsd-power) --------------------------------------------- */

static guint64
idle_ms (App *app)
{
  g_autoptr (GVariant) reply =
    g_dbus_connection_call_sync (app->session, IDLE_BUS, IDLE_PATH, IDLE_BUS, "GetIdletime",
                                 NULL, G_VARIANT_TYPE ("(t)"), G_DBUS_CALL_FLAGS_NONE,
                                 1000, NULL, NULL);
  guint64 ms = 0;

  if (reply != NULL)
    g_variant_get (reply, "(t)", &ms);
  return ms;
}

static void
on_screen_changed (GDBusProxy *proxy, GVariant *changed, GStrv invalidated, gpointer data)
{
  App *app = data;
  int value;

  if (!g_variant_lookup (changed, "Brightness", "i", &value) || value < 0)
    return;
  for (guint i = 0; i < app->written->len; i++) {
    if (g_array_index (app->written, int, i) == value) {
      /* Our own change echoed back, along with any before it. */
      g_array_remove_range (app->written, 0, i + 1);
      return;
    }
  }
  g_array_set_size (app->written, 0);
  app->current = value;
  if (idle_ms (app) >= IDLE_DIM_MS) {
    app->dimmed = TRUE;
    app->fading = FALSE;
  } else if (app->dimmed) {
    app->dimmed = FALSE; /* gsd-power restoring after its dim */
    start_ticking (app);
  } else if (app->have_light) {
    app->bias = from_pct (value) - app->level;
    app->have_bias = TRUE;
    app->fading = FALSE;
    save_bias (app);
  }
}

static void
on_screen_appeared (GDBusConnection *conn, const char *name, const char *owner, gpointer data)
{
  App *app = data;
  g_autoptr (GVariant) value = NULL;

  app->screen = g_dbus_proxy_new_sync (conn, G_DBUS_PROXY_FLAGS_NONE, NULL,
                                       POWER_BUS, POWER_PATH, SCREEN_IFACE, NULL, NULL);
  if (app->screen == NULL)
    return;
  g_signal_connect (app->screen, "g-properties-changed", G_CALLBACK (on_screen_changed), app);
  value = g_dbus_proxy_get_cached_property (app->screen, "Brightness");
  if (value != NULL && g_variant_get_int32 (value) >= 0)
    app->current = g_variant_get_int32 (value);
  start_ticking (app);
}

static void
on_screen_vanished (GDBusConnection *conn, const char *name, gpointer data)
{
  App *app = data;

  g_clear_object (&app->screen);
  g_array_set_size (app->written, 0);
}

static gboolean
quit (gpointer loop)
{
  g_main_loop_quit (loop);
  return G_SOURCE_REMOVE;
}

int
main (void)
{
  g_autoptr (GMainLoop) loop = g_main_loop_new (NULL, FALSE);
  g_autoptr (GError) error = NULL;
  App app = { .current = -1 };

  app.state_file = g_build_filename (g_get_user_state_dir (), "autobrightness.json", NULL);
  app.written = g_array_new (FALSE, FALSE, sizeof (int));
  load_bias (&app);

  app.system = g_bus_get_sync (G_BUS_TYPE_SYSTEM, NULL, &error);
  if (app.system != NULL)
    app.session = g_bus_get_sync (G_BUS_TYPE_SESSION, NULL, &error);
  if (app.session == NULL) {
    g_printerr ("autobrightness: %s\n", error->message);
    return 1;
  }
  g_bus_watch_name_on_connection (app.system, SENSOR_BUS, G_BUS_NAME_WATCHER_FLAGS_NONE,
                                  on_sensor_appeared, on_sensor_vanished, &app, NULL);
  g_bus_watch_name_on_connection (app.session, POWER_BUS, G_BUS_NAME_WATCHER_FLAGS_NONE,
                                  on_screen_appeared, on_screen_vanished, &app, NULL);
  g_unix_signal_add (SIGTERM, quit, loop);
  g_unix_signal_add (SIGINT, quit, loop);
  g_main_loop_run (loop);

  if (app.sensor != NULL)
    g_dbus_proxy_call_sync (app.sensor, "ReleaseLight", NULL, G_DBUS_CALL_FLAGS_NONE,
                            1000, NULL, NULL);
  return 0;
}
