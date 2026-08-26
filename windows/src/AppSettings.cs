using System;
using System.Collections.Generic;
using System.IO;
using System.Text;

namespace ClawdBar
{
    internal enum TrayStyle { Numeric, MiniBar, Mascot, DualBar, Hybrid }

    internal enum SnapCorner { TopLeft, TopRight, BottomLeft, BottomRight }

    /// Single source of truth for every default value. Used by AppSettings and
    /// by the per-setting "reset to default" buttons in the Settings window.
    internal static class Defaults
    {
        public const double PollInterval = 60;
        public const bool LaunchAtLogin = false;
        public const TrayStyle TrayStyle = ClawdBar.TrayStyle.Hybrid;
        public const bool ShowMascot = true;
        public const bool OverlayEnabledOnLaunch = false;
        public const double OverlayOpacity = 1.0;
        public const bool OverlayClickThrough = false;
        public const SnapCorner OverlayDefaultCorner = SnapCorner.TopRight;
        public const bool OverlayLocked = true;
        public const bool NotificationsEnabled = true;
        public const double WarningThreshold = 80;
        public const double CriticalThreshold = 95;
        public const bool NotificationSound = true;
        public const bool NotifyForSession = true;
        public const bool NotifyForWeekly = true;
        public const string ApiBaseUrl = "https://api.anthropic.com";
        public const string ApiModel = "claude-haiku-4-5-20251001";
        public const int OverlaySize = 200;
    }

    /// Replaces macOS UserDefaults with a JSON file under %APPDATA%. Key names
    /// are kept identical to the macOS build so the two are easy to diff.
    internal sealed class AppSettings
    {
        public double PollInterval;
        public bool LaunchAtLogin;
        public TrayStyle TrayStyle;
        public bool ShowMascot;
        public bool OverlayEnabledOnLaunch;
        public double OverlayOpacity;
        public bool OverlayClickThrough;
        public SnapCorner OverlayDefaultCorner;
        public bool OverlayLocked;
        public bool NotificationsEnabled;
        public double WarningThreshold;
        public double CriticalThreshold;
        public bool NotificationSound;
        public bool NotifyForSession;
        public bool NotifyForWeekly;
        public string ApiBaseUrl;
        public string ApiModel;
        public bool OnboardingDone;

        // Windows-only: the overlay is a real top-level window, so we persist
        // its frame ourselves (macOS gets this free via setFrameAutosaveName).
        public int OverlayX;
        public int OverlayY;
        public int OverlayWidth;
        public int OverlayHeight;
        public bool OverlayFrameSaved;

        private readonly string _path;
        private bool _suspendSave;

        public static string DirectoryPath
        {
            get
            {
                return Path.Combine(
                    Environment.GetFolderPath(Environment.SpecialFolder.ApplicationData),
                    "ClawdBar");
            }
        }

        public static string FilePath
        {
            get { return Path.Combine(DirectoryPath, "settings.json"); }
        }

        public AppSettings() : this(FilePath) { }

        public AppSettings(string path)
        {
            _path = path;
            ResetToDefaults();
            Load();
        }

        public void ResetToDefaults()
        {
            PollInterval = Defaults.PollInterval;
            LaunchAtLogin = Defaults.LaunchAtLogin;
            TrayStyle = Defaults.TrayStyle;
            ShowMascot = Defaults.ShowMascot;
            OverlayEnabledOnLaunch = Defaults.OverlayEnabledOnLaunch;
            OverlayOpacity = Defaults.OverlayOpacity;
            OverlayClickThrough = Defaults.OverlayClickThrough;
            OverlayDefaultCorner = Defaults.OverlayDefaultCorner;
            OverlayLocked = Defaults.OverlayLocked;
            NotificationsEnabled = Defaults.NotificationsEnabled;
            WarningThreshold = Defaults.WarningThreshold;
            CriticalThreshold = Defaults.CriticalThreshold;
            NotificationSound = Defaults.NotificationSound;
            NotifyForSession = Defaults.NotifyForSession;
            NotifyForWeekly = Defaults.NotifyForWeekly;
            ApiBaseUrl = Defaults.ApiBaseUrl;
            ApiModel = Defaults.ApiModel;
            OnboardingDone = false;
            OverlayX = 0;
            OverlayY = 0;
            OverlayWidth = Defaults.OverlaySize;
            OverlayHeight = Defaults.OverlaySize;
            OverlayFrameSaved = false;
        }

        private void Load()
        {
            if (!File.Exists(_path)) return;
            JsonValue root;
            try
            {
                root = Json.TryParse(File.ReadAllText(_path, Encoding.UTF8));
            }
            catch
            {
                return;
            }
            if (root == null || root.Type != JsonValue.Kind.Object) return;

            _suspendSave = true;
            PollInterval = Num(root, Key.PollInterval, PollInterval);
            LaunchAtLogin = Flag(root, Key.LaunchAtLogin, LaunchAtLogin);
            TrayStyle = ParseTrayStyle(Str(root, Key.TrayStyle, null), TrayStyle);
            ShowMascot = Flag(root, Key.ShowMascot, ShowMascot);
            OverlayEnabledOnLaunch = Flag(root, Key.OverlayOnLaunch, OverlayEnabledOnLaunch);
            OverlayOpacity = Num(root, Key.OverlayOpacity, OverlayOpacity);
            OverlayClickThrough = Flag(root, Key.OverlayClickThrough, OverlayClickThrough);
            OverlayDefaultCorner = ParseCorner(Str(root, Key.OverlayCorner, null), OverlayDefaultCorner);
            OverlayLocked = Flag(root, Key.OverlayLocked, OverlayLocked);
            NotificationsEnabled = Flag(root, Key.NotificationsEnabled, NotificationsEnabled);
            WarningThreshold = Num(root, Key.WarningThreshold, WarningThreshold);
            CriticalThreshold = Num(root, Key.CriticalThreshold, CriticalThreshold);
            NotificationSound = Flag(root, Key.NotificationSound, NotificationSound);
            NotifyForSession = Flag(root, Key.NotifyForSession, NotifyForSession);
            NotifyForWeekly = Flag(root, Key.NotifyForWeekly, NotifyForWeekly);
            ApiBaseUrl = Str(root, Key.ApiBaseUrl, ApiBaseUrl);
            ApiModel = Str(root, Key.ApiModel, ApiModel);
            OnboardingDone = Flag(root, Key.OnboardingDone, OnboardingDone);
            OverlayX = (int)Num(root, Key.OverlayX, OverlayX);
            OverlayY = (int)Num(root, Key.OverlayY, OverlayY);
            OverlayWidth = (int)Num(root, Key.OverlayWidth, OverlayWidth);
            OverlayHeight = (int)Num(root, Key.OverlayHeight, OverlayHeight);
            OverlayFrameSaved = Flag(root, Key.OverlayFrameSaved, OverlayFrameSaved);
            _suspendSave = false;
        }

        public void Save()
        {
            if (_suspendSave) return;
            var root = JsonValue.NewObject();
            root[Key.PollInterval] = JsonValue.From(PollInterval);
            root[Key.LaunchAtLogin] = JsonValue.From(LaunchAtLogin);
            root[Key.TrayStyle] = JsonValue.From(TrayStyle.ToString());
            root[Key.ShowMascot] = JsonValue.From(ShowMascot);
            root[Key.OverlayOnLaunch] = JsonValue.From(OverlayEnabledOnLaunch);
            root[Key.OverlayOpacity] = JsonValue.From(OverlayOpacity);
            root[Key.OverlayClickThrough] = JsonValue.From(OverlayClickThrough);
            root[Key.OverlayCorner] = JsonValue.From(OverlayDefaultCorner.ToString());
            root[Key.OverlayLocked] = JsonValue.From(OverlayLocked);
            root[Key.NotificationsEnabled] = JsonValue.From(NotificationsEnabled);
            root[Key.WarningThreshold] = JsonValue.From(WarningThreshold);
            root[Key.CriticalThreshold] = JsonValue.From(CriticalThreshold);
            root[Key.NotificationSound] = JsonValue.From(NotificationSound);
            root[Key.NotifyForSession] = JsonValue.From(NotifyForSession);
            root[Key.NotifyForWeekly] = JsonValue.From(NotifyForWeekly);
            root[Key.ApiBaseUrl] = JsonValue.From(ApiBaseUrl);
            root[Key.ApiModel] = JsonValue.From(ApiModel);
            root[Key.OnboardingDone] = JsonValue.From(OnboardingDone);
            root[Key.OverlayX] = JsonValue.From(OverlayX);
            root[Key.OverlayY] = JsonValue.From(OverlayY);
            root[Key.OverlayWidth] = JsonValue.From(OverlayWidth);
            root[Key.OverlayHeight] = JsonValue.From(OverlayHeight);
            root[Key.OverlayFrameSaved] = JsonValue.From(OverlayFrameSaved);

            try
            {
                Directory.CreateDirectory(Path.GetDirectoryName(_path));
                // Write-then-move so a crash mid-write can't truncate settings.
                string temp = _path + ".tmp";
                File.WriteAllText(temp, root.ToJson(), new UTF8Encoding(false));
                if (File.Exists(_path)) File.Delete(_path);
                File.Move(temp, _path);
            }
            catch
            {
                // Best-effort: a failed settings write must never crash the app.
            }
        }

        /// Wipes the settings file. Used by --reset-onboarding and by the
        /// About tab's reset button.
        public static bool DeleteStoredSettings()
        {
            try
            {
                if (File.Exists(FilePath)) File.Delete(FilePath);
                return true;
            }
            catch
            {
                return false;
            }
        }

        private static double Num(JsonValue root, string key, double fallback)
        {
            var v = root[key];
            return v == null ? fallback : v.AsDouble(fallback);
        }

        private static bool Flag(JsonValue root, string key, bool fallback)
        {
            var v = root[key];
            return v == null ? fallback : v.AsBool(fallback);
        }

        private static string Str(JsonValue root, string key, string fallback)
        {
            var v = root[key];
            return v == null ? fallback : v.AsString(fallback);
        }

        public static TrayStyle ParseTrayStyle(string raw, TrayStyle fallback)
        {
            if (string.IsNullOrEmpty(raw)) return fallback;
            foreach (TrayStyle candidate in Enum.GetValues(typeof(TrayStyle)))
            {
                if (string.Equals(candidate.ToString(), raw, StringComparison.OrdinalIgnoreCase)) return candidate;
            }
            return fallback;
        }

        public static SnapCorner ParseCorner(string raw, SnapCorner fallback)
        {
            if (string.IsNullOrEmpty(raw)) return fallback;
            foreach (SnapCorner candidate in Enum.GetValues(typeof(SnapCorner)))
            {
                if (string.Equals(candidate.ToString(), raw, StringComparison.OrdinalIgnoreCase)) return candidate;
            }
            return fallback;
        }

        public static string DisplayName(TrayStyle style)
        {
            switch (style)
            {
                case TrayStyle.Numeric: return "Numeric";
                case TrayStyle.MiniBar: return "Mini Bar";
                case TrayStyle.Mascot: return "Mascot";
                case TrayStyle.DualBar: return "Dual Bar";
                default: return "Hybrid";
            }
        }

        public static string DisplayName(SnapCorner corner)
        {
            switch (corner)
            {
                case SnapCorner.TopLeft: return "Top Left";
                case SnapCorner.TopRight: return "Top Right";
                case SnapCorner.BottomLeft: return "Bottom Left";
                default: return "Bottom Right";
            }
        }

        private static class Key
        {
            public const string PollInterval = "clawdbar.pollInterval";
            public const string LaunchAtLogin = "clawdbar.launchAtLogin";
            public const string TrayStyle = "clawdbar.menuBarStyle";
            public const string ShowMascot = "clawdbar.showMascot";
            public const string OverlayOnLaunch = "clawdbar.overlay.onLaunch";
            public const string OverlayOpacity = "clawdbar.overlay.opacity";
            public const string OverlayClickThrough = "clawdbar.overlay.clickThrough";
            public const string OverlayCorner = "clawdbar.overlay.corner";
            public const string OverlayLocked = "clawdbar.overlay.locked";
            public const string NotificationsEnabled = "clawdbar.notifications.enabled";
            public const string WarningThreshold = "clawdbar.notifications.warning";
            public const string CriticalThreshold = "clawdbar.notifications.critical";
            public const string NotificationSound = "clawdbar.notifications.sound";
            public const string NotifyForSession = "clawdbar.notifications.session";
            public const string NotifyForWeekly = "clawdbar.notifications.weekly";
            public const string ApiBaseUrl = "clawdbar.api.baseURL";
            public const string ApiModel = "clawdbar.api.model";
            public const string OnboardingDone = "clawdbar.onboarding.done";
            public const string OverlayX = "clawdbar.overlay.x";
            public const string OverlayY = "clawdbar.overlay.y";
            public const string OverlayWidth = "clawdbar.overlay.width";
            public const string OverlayHeight = "clawdbar.overlay.height";
            public const string OverlayFrameSaved = "clawdbar.overlay.frameSaved";
        }
    }
}
