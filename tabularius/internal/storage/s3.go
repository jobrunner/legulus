// Package storage keeps the S3 file storage of PocketBase usable: the
// connection can come from the environment (S3_*) instead of the admin
// UI, and a region that no S3 service accepts is caught before every
// upload fails on it.
//
// Background: the admin UI takes any text as region. With the label of
// the Cloudflare dashboard („Europäische Union (EU)“) R2 rejected every
// write with InvalidRegionName, PocketBase answered the app with 400 and
// no photo was ever stored.
package storage

import (
	"errors"
	"fmt"
	"log/slog"
	"net/url"
	"regexp"
	"slices"
	"strconv"
	"strings"
	"sync/atomic"

	"github.com/pocketbase/pocketbase/core"
)

// r2Regions are the location hints Cloudflare R2 accepts as region;
// us-east-1 is its alias for auto, for tools that insist on a region.
var r2Regions = []string{"auto", "wnam", "enam", "weur", "eeur", "apac", "oc", "us-east-1"}

// regionCode is the shape of every S3 region name: lower-case words
// joined by dashes („eu-central-1“, „auto“).
var regionCode = regexp.MustCompile(`^[a-z0-9]+(-[a-z0-9]+)*$`)

// CheckRegion reports why region is no valid region for the S3 service
// at endpoint, nil when it is.
func CheckRegion(endpoint, region string) error {
	// PocketBase signs with the region exactly as stored.
	if region != strings.TrimSpace(region) {
		return fmt.Errorf("S3 region %q has surrounding whitespace", region)
	}
	if isR2(endpoint) {
		if slices.Contains(r2Regions, region) {
			return nil
		}
		return fmt.Errorf("S3 region %q is not valid for Cloudflare R2; use \"auto\" (or one of %s)",
			region, strings.Join(r2Regions[1:len(r2Regions)-1], ", "))
	}
	if !regionCode.MatchString(region) {
		return fmt.Errorf("S3 region %q is no region code (e.g. \"eu-central-1\")", region)
	}
	return nil
}

func isR2(endpoint string) bool {
	endpoint = strings.TrimSpace(endpoint)
	// PocketBase also takes the endpoint without scheme.
	if !strings.Contains(endpoint, "://") {
		endpoint = "https://" + endpoint
	}
	u, err := url.Parse(endpoint)
	if err != nil {
		return false
	}
	return strings.HasSuffix(strings.ToLower(u.Hostname()), ".r2.cloudflarestorage.com")
}

// FromEnv reads the S3 connection from S3_ENDPOINT, S3_BUCKET,
// S3_REGION (default "auto"), S3_ACCESS_KEY, S3_SECRET and
// S3_FORCE_PATH_STYLE. Without S3_ENDPOINT ok is false: the settings of
// the admin UI stay as they are.
func FromEnv(getenv func(string) string) (cfg core.S3Config, ok bool, err error) {
	get := func(k string) string { return strings.TrimSpace(getenv(k)) }
	endpoint := get("S3_ENDPOINT")
	if endpoint == "" {
		return core.S3Config{}, false, nil
	}
	cfg = core.S3Config{
		Enabled:   true,
		Endpoint:  endpoint,
		Bucket:    get("S3_BUCKET"),
		Region:    get("S3_REGION"),
		AccessKey: get("S3_ACCESS_KEY"),
		Secret:    get("S3_SECRET"),
	}
	if cfg.Region == "" {
		cfg.Region = "auto"
	}
	if raw := get("S3_FORCE_PATH_STYLE"); raw != "" {
		v, perr := strconv.ParseBool(raw)
		if perr != nil {
			return core.S3Config{}, true, fmt.Errorf("S3_FORCE_PATH_STYLE: %w", perr)
		}
		cfg.ForcePathStyle = v
	}
	var missing []string
	for _, f := range []struct{ key, value string }{
		{"S3_BUCKET", cfg.Bucket}, {"S3_ACCESS_KEY", cfg.AccessKey}, {"S3_SECRET", cfg.Secret},
	} {
		if f.value == "" {
			missing = append(missing, f.key)
		}
	}
	if len(missing) > 0 {
		return core.S3Config{}, true, fmt.Errorf("S3_ENDPOINT is set, but %s missing", strings.Join(missing, ", "))
	}
	if err := CheckRegion(cfg.Endpoint, cfg.Region); err != nil {
		return core.S3Config{}, true, fmt.Errorf("S3_REGION: %w", err)
	}
	return cfg, true, nil
}

// errManagedByEnv rejects S3 changes in the admin UI while the
// environment sets them; they would be gone after the next start.
var errManagedByEnv = errors.New("the S3 file storage is set by the S3_* environment variables of the container")

// Register applies the S3 connection from the environment on start and
// checks the settings: on start (error log) and when the admin UI saves
// them (rejected with the reason).
func Register(app core.App, getenv func(string) string, logger *slog.Logger) {
	st := newEnvState(getenv)
	app.OnBootstrap().BindFunc(func(e *core.BootstrapEvent) error {
		if err := e.Next(); err != nil {
			return err
		}
		st.bootstrap(e.App, logger)
		return nil
	})
	app.OnSettingsUpdateRequest().BindFunc(st.onSettingsUpdate)
}

// envState is the S3 connection from the environment and whether it
// is in force.
type envState struct {
	cfg     core.S3Config
	fromEnv bool
	err     error
	// managed is set once the environment was applied on start; only
	// then is S3 locked in the admin UI. A failed start leaves the
	// admin UI as the way to repair the storage.
	managed atomic.Bool
}

func newEnvState(getenv func(string) string) *envState {
	st := &envState{}
	st.cfg, st.fromEnv, st.err = FromEnv(getenv)
	return st
}

// bootstrap applies the environment, or checks the stored settings
// when there is none. It never stops the start: everything but file
// uploads works without S3.
func (st *envState) bootstrap(app core.App, logger *slog.Logger) {
	switch {
	case st.err != nil:
		logger.Error("storage: S3 environment not applied", slog.Any("err", st.err))
	case st.fromEnv:
		if err := apply(app, st.cfg); err != nil {
			logger.Error("storage: S3 settings not saved", slog.Any("err", err))
			return
		}
		st.managed.Store(true)
		logger.Info("storage: S3 settings from environment", slog.String("region", st.cfg.Region))
	default:
		if err := checkSettings(app.Settings().S3); err != nil {
			logger.Error("storage: S3 settings unusable, file uploads will fail", slog.Any("err", err))
		}
	}
}

func (st *envState) onSettingsUpdate(e *core.SettingsUpdateRequestEvent) error {
	if st.managed.Load() && e.NewSettings.S3 != e.OldSettings.S3 {
		return e.BadRequestError(errManagedByEnv.Error(), nil)
	}
	if err := checkSettings(e.NewSettings.S3); err != nil {
		return e.BadRequestError(err.Error(), nil)
	}
	return e.Next()
}

// checkSettings checks an enabled S3 storage; a disabled one is fine.
func checkSettings(s3 core.S3Config) error {
	if !s3.Enabled {
		return nil
	}
	return CheckRegion(s3.Endpoint, s3.Region)
}

// apply stores cfg as the S3 file storage, unless it is set already.
// It saves a clone: app.Settings() are the running settings, and a
// failed save must leave them alone (a successful one reloads them).
func apply(app core.App, cfg core.S3Config) error {
	if app.Settings().S3 == cfg {
		return nil
	}
	settings, err := app.Settings().Clone()
	if err != nil {
		return err
	}
	settings.S3 = cfg
	return app.Save(settings)
}
