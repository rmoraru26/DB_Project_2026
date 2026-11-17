/*
 * Audit Lab: the guided tour on /lab.
 *
 * Talks only to the app's own JSON endpoints (/lab/api/...), which run
 * allow-listed statements and return what the server recorded.  Every value
 * from the server is inserted with textContent, never as HTML.
 */
(function () {
    "use strict";

    var root = document.getElementById("lab");
    if (!root) return;

    var TOTAL = 9;
    var STORE_KEY = "campusAuditLab.v1";
    var loggedIn = root.dataset.loggedIn === "true";
    var isAdmin = root.dataset.role === "admin";
    var csrfMeta = document.querySelector('meta[name="csrf-token"]');
    var csrf = csrfMeta ? csrfMeta.content : "";
    var lastResult = null;
    var pluginLoaded = false;

    // ------------------------------------------------------------ persisted progress

    function loadState() {
        try {
            var raw = window.localStorage.getItem(STORE_KEY);
            var parsed = raw ? JSON.parse(raw) : null;
            if (parsed && typeof parsed.step === "number") return parsed;
        } catch (e) { /* private window or blocked storage: start fresh */ }
        return { step: 1, done: {}, completed: false };
    }

    function saveState() {
        try { window.localStorage.setItem(STORE_KEY, JSON.stringify(state)); } catch (e) { /* ignore */ }
    }

    var state = loadState();

    // ------------------------------------------------------------ small DOM helpers

    function el(tag, attrs) {
        var node = document.createElement(tag);
        if (attrs) {
            Object.keys(attrs).forEach(function (key) {
                var value = attrs[key];
                if (value === null || value === undefined || value === false) return;
                if (key === "text") node.textContent = value;
                else if (key === "class") node.className = value;
                else node.setAttribute(key, value === true ? "" : value);
            });
        }
        for (var i = 2; i < arguments.length; i++) {
            var child = arguments[i];
            if (child === null || child === undefined || child === false) continue;
            node.appendChild(typeof child === "string" ? document.createTextNode(child) : child);
        }
        return node;
    }

    function code(text) { return el("code", { text: String(text) }); }

    function clear(node) { while (node.firstChild) node.removeChild(node.firstChild); return node; }

    function show(container) {
        clear(container);
        for (var i = 1; i < arguments.length; i++) if (arguments[i]) container.appendChild(arguments[i]);
    }

    function alertBox(kind, message) {
        return el("div", { class: "alert alert-" + kind + " mb-0", role: kind === "danger" ? "alert" : "status" }, message);
    }

    function loading(text) {
        return el("p", { class: "lab-loading", role: "status" }, el("span", { class: "spinner-border spinner-border-sm", "aria-hidden": "true" }), " " + text);
    }

    // ------------------------------------------------------------ API

    function api(path, options) {
        options = options || {};
        var init = { method: options.method || "GET", credentials: "same-origin", headers: { "Accept": "application/json" } };
        if (init.method !== "GET") {
            init.headers["Content-Type"] = "application/json";
            init.headers["X-CSRF-Token"] = csrf;
            init.body = JSON.stringify(options.body || {});
        }
        return fetch(path, init).then(function (response) {
            return response.json().catch(function () { return {}; }).then(function (data) {
                if (!response.ok) {
                    var message = data.message || ("The server answered " + response.status + ".");
                    if (response.status === 401) message = "Your session has ended. Log in again to use the live steps.";
                    var error = new Error(message);
                    error.status = response.status;
                    throw error;
                }
                return data;
            });
        }, function () {
            throw new Error("The web app is not reachable. Is it still running?");
        });
    }

    // ------------------------------------------------------------ explanations

    var FIELD_HELP = {
        ts: "When the plugin wrote the record: UTC with microseconds, from the plugin's own clock.",
        seq: "Sequence number within this plugin instance. A gap would mean lost records (see audit_gap).",
        instance: "One load of the plugin (INSTALL SONAME or a server start). seq restarts with every instance.",
        event: "Record type: table_* come from TABLE events, statement from GENERAL STATUS, connect*/change_user* from CONNECTION events.",
        conn: "The server's connection id, equal to CONNECTION_ID() of the session. Trigger rows store the same number.",
        query_id: "The server's id of the statement. The table records and the statement record of one statement share it.",
        user: "Login name of the database account. For the web app always campus_app: the server does not know which student acted.",
        priv_user: "Account the server checked privileges against.",
        priv_host: "Host part of that account (% = any host).",
        host: "Client host as the server sees it.",
        ip: "Client IP address.",
        port: "Client TCP port.",
        db: "Schema of the opened table; for statement records the session's default schema.",
        table: "Table the statement opened.",
        new_db: "Schema after a RENAME.",
        new_table: "Table name after a RENAME.",
        account: "user[privilege account] @ host [ip], as the server formats it for GENERAL events.",
        command: "Protocol command; Query for a text statement.",
        error_code: "MariaDB error number of the whole statement; 0 means it succeeded.",
        status: "For statements ok/error; for connection events the error number (0 = success).",
        sql_digest: "The statement with every literal replaced by ?. Values, passwords and personal data never reach the log.",
        sql_digest_truncated: "true if the digest was cut at campus_audit_max_sql_length.",
        access_denied: "The privilege system refused the statement before any table was opened, so no TABLE event exists for it.",
        proxy_user: "Proxy account, if the login used one.",
        tls_version: "TLS version of the connection; empty means no TLS.",
        user_context: "before_change: for CHANGE_USER the account fields describe the session before the switch.",
        dropped_events: "How many records were lost while the log could not be written.",
        last_error: "Why writing the log failed.",
        variable: "System variable that was changed with SET GLOBAL.",
        value: "Its new value.",
        version: "Plugin version.",
        events_written: "Records written by this instance.",
        events_dropped: "Records this instance could not write."
    };

    var EVENT_HELP = {
        table_write: "The server opened this table for writing. This happens before the statement runs, so it does not prove that a row changed.",
        table_read: "The server opened this table for reading (recorded only with campus_audit_log_reads=ON).",
        table_create: "A table was created in a watched schema.",
        table_alter: "A table in a watched schema was altered.",
        table_rename: "A table in a watched schema was renamed.",
        table_drop: "A table in a watched schema was dropped.",
        statement: "The statement finished. This record carries its outcome and the literal-free digest.",
        connect: "A successful login (recorded with campus_audit_connections=ALL).",
        connect_failed: "A failed login. The attempted account name is recorded, the password never.",
        disconnect: "A connection ended.",
        change_user: "COM_CHANGE_USER switched the account of an open connection.",
        change_user_failed: "COM_CHANGE_USER failed; the record names the account before the attempt.",
        config_change: "An administrator changed a campus_audit_* variable.",
        plugin_start: "The plugin was loaded.",
        plugin_stop: "The plugin was unloaded or the server stopped.",
        audit_gap: "The log could not be written for a while; this record says how many records were lost."
    };

    var ACTION_EXPLAIN = {
        create: "One INSERT produced a table_write record for audit_lab_notes, a second table_write for audit_events (the trigger's own write, same query_id) and one statement record with error_code 0.",
        update: "The UPDATE again shows two table_write records and a statement record. The trigger row in step 6 holds the old and new quantity.",
        "delete": "The plugin knows a DELETE ran on audit_lab_notes; only the trigger row keeps the deleted values.",
        violate: "The server opened audit_lab_notes for writing, and audit_events as well, because tables a trigger may write are locked in advance. Then the CHECK constraint failed: the statement record carries error_code 4025. No row changed, no trigger ran, and no trigger row exists.",
        rollback: "The UPDATE succeeded, so the plugin says status ok. The transaction was rolled back afterwards, and the trigger row with it. No audit event reports the rollback.",
        denied: "The privilege check refused the DELETE before the server opened any table, so there is no table_write record. The statement record with access_denied: true comes from the GENERAL STATUS event (plugin version 1.1).",
        failed_login: "A failed login is a CONNECTION event. It has its own connection id, because it never became a session."
    };

    var EMPTY_HISTORY = {
        violate: "No row history: the statement failed, so no row changed and no trigger ran. The plugin still saw the attempt (step 5).",
        rollback: "No row history: the trigger wrote a row, and the ROLLBACK removed it together with your change. The plugin's statement record says ok.",
        denied: "No row history: the server refused the statement before it touched any row.",
        failed_login: "Logins never change rows. Only the plugin's CONNECTION event saw this one."
    };

    // ------------------------------------------------------------ tour navigation

    var steps = Array.prototype.slice.call(root.querySelectorAll(".lab-step"));
    var stepButtons = Array.prototype.slice.call(root.querySelectorAll("#lab-step-list [data-goto]"));
    var progress = root.querySelector(".lab-progress");
    var progressBar = root.querySelector(".lab-progress-bar");
    var progressText = document.getElementById("lab-progress-text");
    var backButton = root.querySelector('.lab-nav [data-tour="back"]');
    var nextButton = root.querySelector('.lab-nav [data-tour="next"]');

    function stepTitle(n) {
        var heading = steps[n - 1] && steps[n - 1].querySelector("h2");
        return heading ? heading.textContent : "";
    }

    function goTo(n, options) {
        options = options || {};
        n = Math.max(1, Math.min(TOTAL, n));
        state.step = n;
        if (n === TOTAL) state.completed = true;
        saveState();
        steps.forEach(function (section, i) { section.hidden = i !== n - 1; });
        stepButtons.forEach(function (button, i) {
            if (i === n - 1) button.setAttribute("aria-current", "step");
            else button.removeAttribute("aria-current");
            button.classList.toggle("is-visited", i < n - 1);
        });
        progress.setAttribute("aria-valuenow", String(n));
        progress.setAttribute("aria-valuetext", "Step " + n + " of " + TOTAL + ": " + stepTitle(n));
        progressBar.style.width = Math.round(n / TOTAL * 100) + "%";
        progressText.textContent = "Step " + n + " of " + TOTAL + " · " + stepTitle(n);
        backButton.disabled = n === 1;
        nextButton.textContent = n === TOTAL ? "Finish" : (n === TOTAL - 1 ? "Finish the tour" : "Next");
        enterStep(n);
        if (options.focus !== false) {
            var heading = steps[n - 1].querySelector("h2");
            if (heading) heading.focus({ preventScroll: true });
            var target = root.querySelector(".lab-shell");
            if (target && target.getBoundingClientRect().top < 0) target.scrollIntoView({ behavior: prefersReducedMotion() ? "auto" : "smooth" });
        }
    }

    function prefersReducedMotion() {
        return window.matchMedia && window.matchMedia("(prefers-reduced-motion: reduce)").matches;
    }

    function enterStep(n) {
        if (!loggedIn) return;
        if (n === 3 && !pluginLoaded) loadPlugin();
        if (n === 4) loadNotes();
        if (n === 5) renderPluginEvents();
        if (n === 6) renderRowHistory();
        if (n === 7) loadEvents();
        if (n === 9) renderSummary();
    }

    root.addEventListener("click", function (event) {
        var target = event.target.closest("button, a");
        if (!target || !root.contains(target)) return;
        var tour = target.getAttribute("data-tour");
        var goto = target.getAttribute("data-goto");
        if (tour === "start") { state.completed = false; goTo(1); }
        else if (tour === "skip") goTo(7);
        else if (tour === "next") { if (state.step === TOTAL) window.location.href = "/"; else goTo(state.step + 1); }
        else if (tour === "back") goTo(state.step - 1);
        else if (tour === "restart") { state = { step: 1, done: {}, completed: false }; lastResult = null; goTo(1); }
        else if (goto) goTo(parseInt(goto, 10));
        else if (target.hasAttribute("data-action")) runAction(target.getAttribute("data-action"));
        else if (target.getAttribute("data-load") === "plugin") loadPlugin();
        else if (target.hasAttribute("data-refresh")) refreshEvents();
        else if (target.hasAttribute("data-reset")) resetNotes();
    });

    document.addEventListener("keydown", function (event) {
        if (event.altKey || event.ctrlKey || event.metaKey) return;
        var tag = (event.target.tagName || "").toLowerCase();
        if (tag === "input" || tag === "select" || tag === "textarea" || event.target.isContentEditable) return;
        if (event.key === "ArrowRight" && state.step < TOTAL) { event.preventDefault(); goTo(state.step + 1); }
        if (event.key === "ArrowLeft" && state.step > 1) { event.preventDefault(); goTo(state.step - 1); }
    });

    // ------------------------------------------------------------ login gating

    if (!loggedIn) {
        var template = document.getElementById("login-needed");
        root.querySelectorAll("[data-needs-login]").forEach(function (block) {
            clear(block).appendChild(template.content.cloneNode(true));
        });
    }

    // ------------------------------------------------------------ step 3: plugin state

    function fact(label, value, help, modifier) {
        return el("div", { class: "lab-fact" + (modifier ? " lab-fact--" + modifier : "") },
            el("dt", { text: label }),
            el("dd", null, value === null || value === undefined || value === "" ? el("span", { class: "text-body-secondary", text: "(empty)" }) : code(value)),
            help ? el("p", { class: "lab-fact-help", text: help }) : null);
    }

    function loadPlugin() {
        var box = document.getElementById("plugin-state");
        show(box, loading("Asking the server…"));
        api("/lab/api/plugin").then(function (data) {
            pluginLoaded = true;
            renderPlugin(box, data);
        }, function (error) {
            show(box, alertBox("danger", error.message));
        });
    }

    function renderPlugin(box, data) {
        var p = data.plugin;
        var status = data.status || {};
        var vars = data.variables || {};
        var writer = status.campus_audit_state || "unknown";
        var headline;
        if (!p) {
            headline = alertBox("danger", "The server has no plugin called campus_audit installed. Run make up (it installs it), or as an administrator: INSTALL SONAME 'campus_audit';");
        } else if (!data.active) {
            headline = alertBox("warning", "campus_audit is known to the server but its status is " + p.PLUGIN_STATUS + ". The server log says why.");
        } else {
            headline = el("div", { class: "lab-status lab-status--" + (writer === "ACTIVE" ? "ok" : "warn") },
                el("span", { class: "lab-status-dot", "aria-hidden": "true" }),
                el("div", null,
                    el("strong", { text: "campus_audit is loaded and " + (writer === "ACTIVE" ? "writing" : writer) }),
                    el("span", { text: " · MariaDB " + data.server_version })));
        }
        var parts = [headline];
        if (p) {
            parts.push(el("h3", { class: "lab-subhead", text: "information_schema.PLUGINS" }));
            parts.push(el("dl", { class: "lab-facts" },
                fact("PLUGIN_STATUS", p.PLUGIN_STATUS, "ACTIVE: init() succeeded and the server calls the plugin for every subscribed event.", data.active ? "ok" : "bad"),
                fact("PLUGIN_TYPE", p.PLUGIN_TYPE + " " + p.PLUGIN_TYPE_VERSION, "An AUDIT plugin, written against the server's audit interface version."),
                fact("PLUGIN_LIBRARY", p.PLUGIN_LIBRARY, "The shared library loaded from the server's plugin_dir."),
                fact("PLUGIN_MATURITY", p.PLUGIN_MATURITY, "The plugin declares itself Beta, so the server must run with plugin_maturity=beta."),
                fact("Version", p.PLUGIN_AUTH_VERSION, "From the plugin descriptor (maria_declare_plugin).")));
        }
        if (Object.keys(status).length) {
            parts.push(el("h3", { class: "lab-subhead", text: "Status variables (SHOW GLOBAL STATUS)" }));
            parts.push(el("dl", { class: "lab-facts" },
                fact("Campus_audit_state", writer, "ACTIVE = writing; DEGRADED = the log cannot be written, records are counted as dropped and an audit_gap record follows; CLOSED = no file open.", writer === "ACTIVE" ? "ok" : "warn"),
                fact("Campus_audit_events_written", status.campus_audit_events_written, "Records this plugin instance has written since it was loaded."),
                fact("Campus_audit_events_dropped", status.campus_audit_events_dropped, "Records lost because the log could not be written. 0 means nothing was lost.", status.campus_audit_events_dropped === "0" ? "ok" : "warn"),
                fact("Campus_audit_events_filtered", status.campus_audit_events_filtered, "Events skipped because their user is in campus_audit_exclude_users."),
                fact("Campus_audit_write_failures", status.campus_audit_write_failures, "Failed write() calls on the log file.")));
        }
        if (Object.keys(vars).length) {
            parts.push(el("h3", { class: "lab-subhead", text: "Configuration (SHOW GLOBAL VARIABLES, all changeable with SET GLOBAL)" }));
            parts.push(el("dl", { class: "lab-facts" },
                fact("campus_audit_databases", vars.campus_audit_databases, "Schemas whose table access is recorded. The lab table lives in university_resources for that reason."),
                fact("campus_audit_connections", vars.campus_audit_connections, "NONE, FAILED or ALL: which logins are recorded. With FAILED, the failed-login button in step 4 produces a record."),
                fact("campus_audit_log_reads", vars.campus_audit_log_reads, "OFF: reads (SELECT) are not recorded, because they would dominate the log."),
                fact("campus_audit_max_sql_length", vars.campus_audit_max_sql_length, "Longest digest in bytes; 0 switches digests off."),
                fact("campus_audit_exclude_users", vars.campus_audit_exclude_users, "Logins whose activity is not recorded."),
                fact("campus_audit_file_path", vars.campus_audit_file_path, "The JSON Lines file the plugin appends to.")));
        }
        if (!data.import_available) {
            parts.push(alertBox("warning", "The import procedure campus_audit.import_current_log() is missing: this database predates migration 003. Run make migrate (or make up), then reload."));
        }
        show.apply(null, [box].concat(parts));
    }

    // ------------------------------------------------------------ step 4: actions

    var actionButtons = Array.prototype.slice.call(root.querySelectorAll("[data-action]"));

    function runAction(action) {
        var box = document.getElementById("action-result");
        var label = document.getElementById("lab-label");
        var quantity = document.getElementById("lab-quantity");
        actionButtons.forEach(function (b) { b.disabled = true; });
        show(box, loading("Running the statement on the server…"));
        api("/lab/api/action", { method: "POST", body: {
            action: action,
            label: label ? label.value : "",
            quantity: quantity ? quantity.value : "1"
        } }).then(function (result) {
            lastResult = result;
            state.done[action] = true;
            saveState();
            renderActionResult(box, result);
            renderNotes(result.notes || []);
        }, function (error) {
            show(box, alertBox(error.status === 409 ? "info" : "danger", error.message));
        }).then(function () {
            actionButtons.forEach(function (b) { b.disabled = false; });
        });
    }

    function renderActionResult(box, result) {
        var outcome = result.outcome;
        var plugin = result.plugin;
        var banner = el("div", { class: "lab-outcome lab-outcome--" + (outcome.ok ? "ok" : "error") },
            el("span", { class: "lab-chip lab-chip--" + (outcome.ok ? "ok" : "error"), text: outcome.ok ? "succeeded" : "failed" }),
            el("span", { text: " " + outcome.message }));
        var meta = el("p", { class: "lab-meta" },
            "Ran on connection ", code(result.connection_id),
            result.statement ? el("span", null, " · statement sent by the app: ", code(result.statement)) : null);
        var counts = el("div", { class: "lab-counts" },
            el("button", { type: "button", class: "lab-count lab-count--plugin", "data-goto": "5" },
                el("strong", { text: String(plugin.events.length) }), " plugin record" + (plugin.events.length === 1 ? "" : "s"), el("span", { text: "see step 5 →" })),
            el("button", { type: "button", class: "lab-count lab-count--trigger", "data-goto": "6" },
                el("strong", { text: String(result.history.length) }), " trigger row" + (result.history.length === 1 ? "" : "s"), el("span", { text: "see step 6 →" })));
        var explain = el("p", { class: "lab-explain", text: ACTION_EXPLAIN[result.action] || "" });
        var problem = plugin.error ? alertBox("warning", plugin.error) : null;
        show(box, banner, meta, counts, explain, problem);
    }

    function loadNotes() {
        api("/lab/api/notes").then(function (data) { renderNotes(data.notes || []); }, function () { /* shown on action */ });
    }

    function renderNotes(notes) {
        var box = document.getElementById("lab-notes");
        if (!box) return;
        if (!notes.length) { show(box, el("p", { class: "text-body-secondary small mb-0", text: "No lab rows yet." })); return; }
        var body = el("tbody");
        notes.forEach(function (n) {
            body.appendChild(el("tr", null, el("td", { text: "#" + n.note_id }), el("td", { text: n.label }), el("td", { text: String(n.quantity) }), el("td", { text: n.updated_at })));
        });
        show(box, el("div", { class: "table-responsive" }, el("table", { class: "table table-sm mb-0" },
            el("thead", null, el("tr", null, el("th", { text: "Row" }), el("th", { text: "Label" }), el("th", { text: "Quantity" }), el("th", { text: "Last change" }))), body)));
    }

    function resetNotes() {
        if (!window.confirm("Delete all of your lab rows? (Other users' rows and the audit records stay.)")) return;
        api("/lab/api/reset", { method: "POST" }).then(function (data) {
            renderNotes([]);
            show(document.getElementById("action-result"), alertBox("info", "Deleted " + data.removed + " lab row(s). The DELETE was audited like any other statement."));
        }, function (error) {
            show(document.getElementById("action-result"), alertBox("danger", error.message));
        });
    }

    // ------------------------------------------------------------ step 5: plugin records

    function eventKind(type) {
        if (type.indexOf("table_") === 0) return { cls: "table", label: "TABLE event" };
        if (type === "statement") return { cls: "statement", label: "GENERAL STATUS" };
        if (type.indexOf("connect") === 0 || type === "disconnect" || type.indexOf("change_user") === 0) return { cls: "connection", label: "CONNECTION event" };
        return { cls: "lifecycle", label: "plugin itself" };
    }

    function eventOutcome(ev) {
        var r = ev.record || {};
        if (ev.event_type === "statement") return r.error_code === 0 ? "ok" : "error";
        if (ev.event_type === "connect_failed" || ev.event_type === "change_user_failed" || ev.event_type === "audit_gap") return "error";
        return null;
    }

    function eventCard(ev, compact) {
        var r = ev.record || {};
        var kind = eventKind(ev.event_type);
        var outcome = eventOutcome(ev);
        var head = el("header", { class: "ev-head" },
            el("span", { class: "lab-chip lab-chip--plugin", text: "campus_audit" }),
            el("span", { class: "ev-kind ev-kind--" + kind.cls, text: kind.label }),
            el("strong", { class: "ev-type", text: ev.event_type }),
            outcome ? el("span", { class: "lab-chip lab-chip--" + outcome, text: outcome === "ok" ? "error_code 0" : ("error " + (r.error_code !== undefined ? r.error_code : r.status)) }) : null,
            r.access_denied ? el("span", { class: "lab-chip lab-chip--error", text: "access denied" }) : null,
            el("span", { class: "ev-time", text: r.ts || ev.event_time }));
        var where = [];
        if (r.db || r.table) where.push((r.db || "?") + (r.table ? "." + r.table : ""));
        if (r.conn !== undefined) where.push("conn " + r.conn);
        if (r.query_id !== undefined) where.push("query " + r.query_id);
        if (r.user || r.account) where.push(r.user || r.account);
        var summary = el("p", { class: "ev-where", text: where.join(" · ") });
        var digest = r.sql_digest ? el("pre", { class: "ev-digest" }, code(r.sql_digest)) : null;
        var help = el("p", { class: "ev-help", text: EVENT_HELP[ev.event_type] || "" });

        var rows = el("tbody");
        Object.keys(r).forEach(function (key) {
            var value = r[key];
            rows.appendChild(el("tr", null,
                el("th", { scope: "row" }, code(key)),
                el("td", null, value === null ? el("span", { class: "text-body-secondary", text: "null (not available, never invented)" }) : code(typeof value === "object" ? JSON.stringify(value) : String(value))),
                el("td", { class: "ev-field-help", text: FIELD_HELP[key] || "" })));
        });
        var fields = el("details", { class: "ev-details" }, el("summary", { text: "What each field means" }),
            el("div", { class: "table-responsive" }, el("table", { class: "table table-sm ev-fields" },
                el("thead", null, el("tr", null, el("th", { text: "Field" }), el("th", { text: "Value" }), el("th", { text: "Meaning" }))), rows)));
        var raw = el("details", { class: "ev-details" }, el("summary", { text: "Raw JSON line" }),
            el("pre", { class: "ev-raw" }, code(JSON.stringify(r))));
        return el("article", { class: "ev ev--plugin" + (compact ? " ev--compact" : "") }, head, summary, digest, compact ? null : help, fields, raw);
    }

    function needResult(box) {
        show(box, el("div", { class: "lab-empty" },
            el("p", { text: "Run one of the statements in step 4 first; this step shows what the server recorded for it." }),
            el("button", { type: "button", class: "btn btn-primary btn-sm", "data-goto": "4", text: "Go to step 4" })));
    }

    function renderPluginEvents() {
        var box = document.getElementById("plugin-events");
        if (!lastResult) { needResult(box); return; }
        var plugin = lastResult.plugin;
        var intro = el("p", { class: "lab-meta" }, "Action: ", el("strong", { text: lastResult.title }), " · connection ", code(lastResult.connection_id));
        if (plugin.error) { show(box, intro, alertBox("warning", plugin.error)); return; }
        if (!plugin.events.length) {
            var why = lastResult.action === "failed_login"
                ? "No connect_failed record was found. With campus_audit_connections=NONE failed logins are not recorded (step 3 shows the setting)."
                : "The plugin recorded nothing for this connection. Is the plugin ACTIVE and is university_resources in campus_audit_databases (step 3)?";
            show(box, intro, alertBox("info", why));
            return;
        }
        var list = el("div", { class: "ev-list" });
        plugin.events.forEach(function (ev) { list.appendChild(eventCard(ev, false)); });
        show(box, intro, el("p", { class: "lab-explain", text: ACTION_EXPLAIN[lastResult.action] || "" }), list);
    }

    // ------------------------------------------------------------ step 6: row history

    function historyCard(row) {
        var oldV = row.old_values || {};
        var newV = row.new_values || {};
        var keys = Object.keys(Object.assign({}, oldV, newV));
        var body = el("tbody");
        keys.forEach(function (key) {
            var before = oldV[key];
            var after = newV[key];
            var changed = row.action === "UPDATE" && JSON.stringify(before) !== JSON.stringify(after);
            body.appendChild(el("tr", { class: changed ? "is-changed" : null },
                el("th", { scope: "row" }, code(key)),
                el("td", { text: before === undefined ? "–" : String(before) }),
                el("td", { text: after === undefined ? "–" : String(after) })));
        });
        return el("article", { class: "ev ev--trigger" },
            el("header", { class: "ev-head" },
                el("span", { class: "lab-chip lab-chip--trigger", text: "SQL trigger" }),
                el("strong", { class: "ev-type", text: row.action + " " + row.entity_table + " #" + row.entity_id }),
                el("span", { class: "ev-time", text: row.event_time })),
            el("p", { class: "ev-where", text: "audit_events #" + row.event_id + " · database_user " + row.database_user +
                " · application_user_id " + (row.application_user_id === null ? "NULL" : row.application_user_id) +
                " · event_source " + row.event_source + " · connection_id " + row.connection_id }),
            el("div", { class: "table-responsive" }, el("table", { class: "table table-sm ev-diff" },
                el("thead", null, el("tr", null, el("th", { text: "Column" }), el("th", { text: "old_values" }), el("th", { text: "new_values" }))), body)));
    }

    function renderRowHistory() {
        var box = document.getElementById("row-history");
        if (!lastResult) { needResult(box); return; }
        var intro = el("p", { class: "lab-meta" }, "Action: ", el("strong", { text: lastResult.title }), " · connection ", code(lastResult.connection_id));
        if (!lastResult.history.length) {
            show(box, intro, alertBox("info", EMPTY_HISTORY[lastResult.action] || "The triggers wrote no row for this connection."));
            return;
        }
        var list = el("div", { class: "ev-list" });
        lastResult.history.forEach(function (row) { list.appendChild(historyCard(row)); });
        var label = document.getElementById("lab-label");
        var note = lastResult.action === "create" && label
            ? el("p", { class: "lab-explain" }, "Compare: your label ", code(label.value), " is stored here in new_values, while the plugin's digest in step 5 shows only ?.")
            : null;
        show(box, intro, note, list);
    }

    // ------------------------------------------------------------ step 7: explorer

    var tabs = Array.prototype.slice.call(root.querySelectorAll('[role="tab"]'));
    tabs.forEach(function (tab, index) {
        tab.addEventListener("click", function () { selectTab(index); });
        tab.addEventListener("keydown", function (event) {
            if (event.key === "ArrowRight" || event.key === "ArrowLeft") {
                event.preventDefault();
                event.stopPropagation();
                var next = (index + (event.key === "ArrowRight" ? 1 : tabs.length - 1)) % tabs.length;
                selectTab(next);
                tabs[next].focus();
            }
        });
    });

    function selectTab(index) {
        tabs.forEach(function (tab, i) {
            var selected = i === index;
            tab.setAttribute("aria-selected", selected ? "true" : "false");
            tab.tabIndex = selected ? 0 : -1;
            document.getElementById(tab.getAttribute("aria-controls")).hidden = !selected;
        });
        if (index === 1) loadHistory();
    }

    function query(form) {
        var params = new URLSearchParams();
        Array.prototype.forEach.call(form.elements, function (field) {
            if (field.name && field.value) params.append(field.name, field.value);
        });
        return params.toString();
    }

    function loadEvents() {
        var form = document.getElementById("event-filters");
        var box = document.getElementById("event-list");
        if (!form || !box) return;
        show(box, loading("Reading campus_audit.plugin_events…"));
        api("/lab/api/events?" + query(form)).then(function (data) {
            if (!data.events.length) {
                show(box, alertBox("info", data.scope === "all"
                    ? "No records match. Try a longer time range, or Refresh to import what the plugin wrote since."
                    : "No records of your lab actions match. Run an action in step 4, or widen the filters."));
                return;
            }
            var list = el("div", { class: "ev-list" });
            data.events.forEach(function (ev) { list.appendChild(eventCard(ev, true)); });
            show(box, el("p", { class: "lab-meta", text: data.events.length + " record(s), newest first" + (data.events.length >= 200 ? " (first 200)" : "") }), list);
        }, function (error) { show(box, alertBox("danger", error.message)); });
    }

    function refreshEvents() {
        var box = document.getElementById("event-list");
        show(box, loading("Importing the plugin's log…"));
        api("/lab/api/import", { method: "POST" }).then(function (summary) {
            loadEvents();
            var note = document.createElement("p");
            note.className = "lab-meta";
            note.textContent = "Imported " + summary.newly_imported + " new record(s) from " + summary.total_lines + " line(s).";
            box.parentNode.insertBefore(note, box);
            window.setTimeout(function () { if (note.parentNode) note.parentNode.removeChild(note); }, 6000);
        }, function (error) { show(box, alertBox("danger", error.message)); });
    }

    function loadHistory() {
        var form = document.getElementById("history-filters");
        var box = document.getElementById("history-list");
        if (!form || !box) return;
        show(box, loading("Reading audit_events…"));
        api("/lab/api/history?" + query(form)).then(function (data) {
            if (!data.history.length) { show(box, alertBox("info", "No row changes match.")); return; }
            var list = el("div", { class: "ev-list" });
            data.history.forEach(function (row) { list.appendChild(historyCard(row)); });
            show(box, el("p", { class: "lab-meta", text: data.history.length + " row change(s), newest first" }), list);
        }, function (error) { show(box, alertBox("danger", error.message)); });
    }

    ["event-filters", "history-filters"].forEach(function (id) {
        var form = document.getElementById(id);
        if (form) form.addEventListener("submit", function (event) {
            event.preventDefault();
            if (id === "event-filters") loadEvents(); else loadHistory();
        });
    });

    // ------------------------------------------------------------ step 9: summary

    function renderSummary() {
        var box = document.getElementById("lab-summary");
        var names = {
            create: "Inserted a row: two table_write records and a statement record",
            update: "Updated a row: the trigger kept old and new values",
            "delete": "Deleted a row: only the trigger kept the values",
            violate: "Broke a CHECK constraint: table_write without a row change",
            rollback: "Rolled back an UPDATE: the plugin still says ok",
            denied: "Ran a forbidden statement: refused before any table was opened",
            failed_login: "Failed a login: a CONNECTION event"
        };
        var list = el("ul", { class: "lab-checklist lab-checklist--done" });
        Object.keys(names).forEach(function (key) {
            list.appendChild(el("li", { class: state.done[key] ? "is-done" : "is-open" },
                el("span", { class: "visually-hidden", text: state.done[key] ? "done: " : "not tried: " }), names[key]));
        });
        var tried = Object.keys(names).filter(function (k) { return state.done[k]; }).length;
        show(box, el("p", { class: "lab-explain", text: "You tried " + tried + " of " + Object.keys(names).length + " statements. Every record you saw was written by the plugin inside the running server." }), list);
    }

    // ------------------------------------------------------------ start

    var params = new URLSearchParams(window.location.search);
    var requested = parseInt(params.get("step"), 10);
    goTo(requested >= 1 && requested <= TOTAL ? requested : state.step, { focus: false });
})();
