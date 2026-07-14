import { createElement } from "lwc";
import LmOrgLimits from "c/lmOrgLimits";

// The component consumes getLimits/getEntitlements imperatively. Resolved
// values are configured in the jest.mock factory itself and NOT imported at
// the top of this file: with @lwc/jest-transformer, a top-level import of a
// virtual @salesforce/apex module makes the component's own require of that
// module fall back to a broken stub, so assert on rendered DOM instead.
jest.mock(
  "@salesforce/apex/LM_OrgLimitsController.getLimits",
  () => ({
    default: jest.fn(() =>
      Promise.resolve([
        { name: "DailyApiRequests", used: 10, max: 100 },
        { name: "DataStorageMB", used: 5, max: 50 }
      ])
    )
  }),
  { virtual: true }
);
jest.mock(
  "@salesforce/apex/LM_OrgLimitsController.getEntitlements",
  () => ({
    default: jest.fn(() =>
      Promise.resolve([
        {
          setting: "CRM Analytics Rows",
          amountUsed: 1,
          amountAllowed: 10,
          frequency: "Monthly"
        }
      ])
    )
  }),
  { virtual: true }
);

// Let the connectedCallback promise chain settle before asserting. Two
// microtask ticks cover the resolved fetch plus the reactive re-render.
const flushPromises = () => Promise.resolve().then(() => Promise.resolve());

describe("c-lm-org-limits", () => {
  afterEach(() => {
    while (document.body.firstChild)
      document.body.removeChild(document.body.firstChild);
    jest.clearAllMocks();
  });

  it("renders a row per limit returned", async () => {
    const el = createElement("c-lm-org-limits", { is: LmOrgLimits });
    document.body.appendChild(el);
    await flushPromises();

    const rows = el.shadowRoot.querySelectorAll('[data-id="limit-row"]');
    expect(rows.length).toBe(2);
  });

  it("renders a row per entitlement returned", async () => {
    const el = createElement("c-lm-org-limits", { is: LmOrgLimits });
    document.body.appendChild(el);
    await flushPromises();

    const rows = el.shadowRoot.querySelectorAll('[data-id="entitlement-row"]');
    expect(rows.length).toBe(1);
  });
});
