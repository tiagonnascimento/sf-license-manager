import { LightningElement } from "lwc";
import getLimits from "@salesforce/apex/LM_OrgLimitsController.getLimits";
import getEntitlements from "@salesforce/apex/LM_OrgLimitsController.getEntitlements";

/**
 * Org-wide capacity widget for the License Manager analytics dashboard (#3).
 *
 * Reads org-level limit gauges (`OrgLimits`) and billed usage entitlements
 * (`TenantUsageEntitlement`) via `LM_OrgLimitsController`. These metrics are
 * org-scoped and NOT attributable per purchase, so they sit outside the
 * per-purchase financial model.
 *
 * Data is fetched imperatively in `connectedCallback` rather than via `@wire`:
 * both controller methods are one-shot, parameterless reads with no reactive
 * inputs, so there is nothing for a wire to react to.
 */
export default class LmOrgLimits extends LightningElement {
  limits = [];
  entitlements = [];
  error;

  connectedCallback() {
    getLimits()
      .then((data) => {
        this.limits = (data || []).map((r) => ({
          ...r,
          pct: r.max > 0 ? Math.round((r.used / r.max) * 100) : 0
        }));
      })
      .catch((e) => {
        this.error = e?.body?.message || e?.message || "Unknown error";
      });

    getEntitlements()
      .then((data) => {
        this.entitlements = (data || []).map((r) => {
          // AmountUsed can come back null (nothing consumed yet); treat as 0
          // so the value and the bar still render.
          const used = r.amountUsed || 0;
          const allowed = r.amountAllowed || 0;
          return {
            ...r,
            amountUsed: used,
            amountAllowed: allowed,
            pct: allowed > 0 ? Math.round((used / allowed) * 100) : 0
          };
        });
      })
      .catch((e) => {
        this.error = e?.body?.message || e?.message || "Unknown error";
      });
  }
}
