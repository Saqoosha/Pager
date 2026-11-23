import { bindings, defineConfig } from "cf/config";


export default defineConfig({
	accountId: "0f56ad2619afc619cc2975dd0728f8a9",
	worker: {
		name: "pager-relay",
		compatibilityDate: "2024-12-01",
		entrypoint: "src/index.ts",
		observability: {
			enabled: true,
			headSamplingRate: 1,
		},
		env: {
			APNS_BUNDLE_ID: bindings.text("sh.saqoo.pager-app"),
			APNS_KEY_ID: bindings.text("SRH3669YH6"),
			APNS_TEAM_ID: bindings.text("VCFY2GFR89"),
			APNS_USE_SANDBOX: bindings.text("false"),
			REQUESTS: bindings.kv({
				id: "47152719f9a743f48c25bef951cb1352",
			}),
		},
	},
});
