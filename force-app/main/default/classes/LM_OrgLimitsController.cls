/**
 * Read-only Apex controller exposing org-wide limit gauges (`OrgLimits`) and
 * billed usage entitlements (`TenantUsageEntitlement`) for the License Manager
 * capacity dashboard (LWC, see issue #3).
 */
public with sharing class LM_OrgLimitsController {
  /**
   * A single org-wide limit gauge, e.g. Daily API Requests.
   */
  public class LimitRow {
    @AuraEnabled
    public String name;
    @AuraEnabled
    public Integer used;
    @AuraEnabled
    public Integer max;
  }

  /**
   * A single billed usage entitlement row (e.g. CRM Analytics rows, add-on seats).
   */
  public class EntitlementRow {
    @AuraEnabled
    public String setting;
    @AuraEnabled
    public Decimal amountUsed;
    @AuraEnabled
    public Decimal amountAllowed;
    @AuraEnabled
    public String frequency;
  }

  /**
   * @return every org-wide limit reported by `OrgLimits.getMap()`, with current
   * usage and the org's ceiling for each.
   */
  @AuraEnabled(cacheable=true)
  public static List<LimitRow> getLimits() {
    List<LimitRow> rows = new List<LimitRow>();
    for (String key : OrgLimits.getMap().keySet()) {
      System.OrgLimit ol = OrgLimits.getMap().get(key);
      LimitRow r = new LimitRow();
      r.name = ol.getName();
      r.used = ol.getValue();
      r.max = ol.getLimit();
      rows.add(r);
    }
    return rows;
  }

  /**
   * @return every `TenantUsageEntitlement` row visible to the running user, or
   * an empty list if the object is not queryable in this org edition (never
   * throws).
   */
  @AuraEnabled(cacheable=true)
  public static List<EntitlementRow> getEntitlements() {
    List<EntitlementRow> rows = new List<EntitlementRow>();
    try {
      for (TenantUsageEntitlement e : [
        SELECT MasterLabel, Setting, AmountUsed, CurrentAmountAllowed, Frequency
        FROM TenantUsageEntitlement
        WITH USER_MODE
      ]) {
        EntitlementRow r = new EntitlementRow();
        r.setting = e.Setting != null ? e.Setting : e.MasterLabel;
        r.amountUsed = e.AmountUsed;
        r.amountAllowed = e.CurrentAmountAllowed;
        r.frequency = e.Frequency;
        rows.add(r);
      }
    } catch (Exception ex) {
      // TenantUsageEntitlement may be non-queryable in some org editions, or
      // WITH USER_MODE may throw for a running user lacking field access.
      // Degrade gracefully to an empty list rather than surfacing an error on
      // this read-only capacity widget.
      return new List<EntitlementRow>();
    }
    return rows;
  }
}
