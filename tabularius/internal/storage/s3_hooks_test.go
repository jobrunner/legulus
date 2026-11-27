package storage

import (
	"io"
	"log/slog"
	"net/http"
	"strings"
	"testing"

	"github.com/pocketbase/pocketbase/core"
	"github.com/pocketbase/pocketbase/tests"

	"go.mett.io/tabularius/internal/testutil"
	_ "go.mett.io/tabularius/migrations"
)

var quiet = slog.New(slog.NewTextHandler(io.Discard, nil))

func r2Config(region string) core.S3Config {
	return core.S3Config{
		Enabled: true, Endpoint: r2Endpoint, Bucket: "photos", Region: region,
		AccessKey: "key", Secret: "secret",
	}
}

func TestApply_StoresConfigOnce(t *testing.T) {
	app := testutil.NewTestApp(t)
	cfg := r2Config("auto")
	if err := apply(app, cfg); err != nil {
		t.Fatal(err)
	}
	if got := app.Settings().S3; got != cfg {
		t.Fatalf("settings not applied: %+v", got)
	}
	// A second start with the same environment leaves the stored row alone.
	if err := apply(app, cfg); err != nil {
		t.Fatal(err)
	}
}

// A save that fails (here: PocketBase's own validation, no endpoint
// URL) must leave the running settings as they were.
func TestApply_FailedSaveKeepsActiveSettings(t *testing.T) {
	app := testutil.NewTestApp(t)
	before := app.Settings().S3
	bad := r2Config("auto")
	bad.Endpoint = "not a url"
	if err := apply(app, bad); err == nil {
		t.Fatal("invalid endpoint must not save")
	}
	if got := app.Settings().S3; got != before {
		t.Errorf("active settings changed by a failed save: %+v", got)
	}
}

func superuserToken(t *testing.T, app *tests.TestApp) string {
	t.Helper()
	su, err := app.FindAuthRecordByEmail(core.CollectionNameSuperusers, "test@example.com")
	if err != nil {
		t.Fatalf("fixture superuser: %v", err)
	}
	tok, err := su.NewAuthToken()
	if err != nil {
		t.Fatal(err)
	}
	return tok
}

// settingsScenario saves settings over the API with the storage hooks
// in place; with vars the environment was applied on start first.
func settingsScenario(t *testing.T, app *tests.TestApp, vars map[string]string, body string, status int,
	content []string,
) tests.ApiScenario {
	st := newEnvState(env(vars))
	st.bootstrap(app, quiet)
	return tests.ApiScenario{
		Method:          http.MethodPatch,
		URL:             "/api/settings",
		Body:            strings.NewReader(body),
		Headers:         map[string]string{"Authorization": superuserToken(t, app), "Content-Type": "application/json"},
		ExpectedStatus:  status,
		ExpectedContent: content,
		TestAppFactory:  func(testing.TB) *tests.TestApp { return app },
		// The test owns the app.
		DisableTestAppCleanup: true,
		BeforeTestFunc: func(_ testing.TB, app *tests.TestApp, _ *core.ServeEvent) {
			app.OnSettingsUpdateRequest().BindFunc(st.onSettingsUpdate)
		},
	}
}

// The admin UI may not store the dashboard label as region.
func TestSettingsUpdate_RejectsInvalidRegion(t *testing.T) {
	app := testutil.NewTestApp(t)
	body := `{"s3":{"enabled":true,"endpoint":"` + r2Endpoint + `","bucket":"photos",` +
		`"region":"Europäische Union (EU)","accessKey":"key","secret":"secret"}}`
	sc := settingsScenario(t, app, nil, body, http.StatusBadRequest, []string{`not valid for Cloudflare R2`})
	sc.Test(t)
	if app.Settings().S3.Enabled {
		t.Error("rejected settings must not be stored")
	}
}

func TestSettingsUpdate_AcceptsValidRegion(t *testing.T) {
	app := testutil.NewTestApp(t)
	body := `{"s3":{"enabled":true,"endpoint":"` + r2Endpoint + `","bucket":"photos",` +
		`"region":"auto","accessKey":"key","secret":"secret"}}`
	sc := settingsScenario(t, app, nil, body, http.StatusOK, []string{`"region":"auto"`})
	sc.Test(t)
}

// With S3_* in the environment the admin UI may not change S3; the
// next start would overwrite it again.
func TestSettingsUpdate_RejectsS3ChangeWhenManagedByEnv(t *testing.T) {
	app := testutil.NewTestApp(t)
	vars := map[string]string{
		"S3_ENDPOINT": r2Endpoint, "S3_BUCKET": "photos", "S3_ACCESS_KEY": "key", "S3_SECRET": "secret",
	}
	body := `{"s3":{"bucket":"other"}}`
	sc := settingsScenario(t, app, vars, body, http.StatusBadRequest, []string{`S3_* environment variables`})
	sc.Test(t)
	if app.Settings().S3.Bucket != "photos" {
		t.Error("bucket must stay as the environment sets it")
	}
}

// Other settings stay editable while S3 comes from the environment.
func TestSettingsUpdate_OtherSettingsStayEditableWhenManagedByEnv(t *testing.T) {
	app := testutil.NewTestApp(t)
	vars := map[string]string{
		"S3_ENDPOINT": r2Endpoint, "S3_BUCKET": "photos", "S3_ACCESS_KEY": "key", "S3_SECRET": "secret",
	}
	sc := settingsScenario(t, app, vars, `{"meta":{"appName":"Tabularius Test"}}`, http.StatusOK,
		[]string{`"appName":"Tabularius Test"`})
	sc.Test(t)
}

// The environment could not be saved on start (here: no endpoint URL,
// which only PocketBase's validation catches): S3 is not locked, the
// admin UI can still repair the storage.
func TestSettingsUpdate_NoLockWhenEnvironmentWasNotApplied(t *testing.T) {
	app := testutil.NewTestApp(t)
	vars := map[string]string{
		"S3_ENDPOINT": "not a url", "S3_BUCKET": "photos", "S3_ACCESS_KEY": "key", "S3_SECRET": "secret",
	}
	body := `{"s3":{"enabled":true,"endpoint":"` + r2Endpoint + `","bucket":"photos",` +
		`"region":"auto","accessKey":"key","secret":"secret"}}`
	sc := settingsScenario(t, app, vars, body, http.StatusOK, []string{`"region":"auto"`})
	sc.Test(t)
	if app.Settings().S3.Endpoint != r2Endpoint {
		t.Errorf("repair must be stored: %+v", app.Settings().S3)
	}
}
