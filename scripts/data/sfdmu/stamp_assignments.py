#!/usr/bin/env python3
"""
Stamp LM_ProductLicenseUserAssignment__c.csv with PurchaseCondition__c and Persona__c.
Implements the same weighted partition logic as LM_AssignmentAllocator.cls.
"""
import csv
from collections import defaultdict
from decimal import Decimal, ROUND_HALF_UP
from datetime import datetime
import sys


def parse_date(date_str):
    """Parse YYYY-MM-DD date string."""
    if not date_str:
        return None
    try:
        return datetime.strptime(date_str, '%Y-%m-%d').date()
    except ValueError:
        return None


def allocate(sorted_ids, allocations):
    """
    Deterministic weighted partition matching LM_AssignmentAllocator.cls.

    Args:
        sorted_ids: List of assignment IDs in sort order (by Id)
        allocations: List of (purchase_id, weight, purchase_date) tuples

    Returns:
        List of purchase_condition_ids in the same order as sorted_ids
    """
    total = len(sorted_ids)
    if not allocations:
        return [None] * total

    # Sort by purchaseDate ASC (nulls last) to match ByPurchaseDate comparator
    allocations = sorted(allocations, key=lambda x: (x[2] is None, x[2] or datetime.min.date()))

    sum_weight = sum(Decimal(str(a[1] or 0)) for a in allocations)

    # Compute slice counts: all but last are rounded HALF_UP; last takes remainder
    counts = []
    assigned = 0
    for i, (purchase_id, weight, _) in enumerate(allocations):
        if i == len(allocations) - 1:
            counts.append(total - assigned)  # remainder → most recent purchaseDate
        else:
            w = Decimal(str(weight or 0))
            if sum_weight == 0:
                c = 0
            else:
                c = int(((w / sum_weight) * total).quantize(Decimal('1'), ROUND_HALF_UP))
            if assigned + c > total:
                c = total - assigned
            counts.append(c)
            assigned += c

    # Build result
    result = []
    for i, count in enumerate(counts):
        result.extend([allocations[i][0]] * count)

    return result


def main():
    script_dir = '/Users/tnascimento/dev/sf-license-manager/scripts/data/sfdmu'

    # Read ProductLicense → Persona mapping
    license_to_persona = {}
    with open(f'{script_dir}/LM_ProductLicensePersona__c.csv', 'r', encoding='utf-8') as f:
        reader = csv.DictReader(f)
        for row in reader:
            license_id = row['ProductLicense__c']
            persona_id = row['Id']
            license_to_persona[license_id] = persona_id

    # Read allocation junction
    allocations_by_persona = defaultdict(list)
    with open(f'{script_dir}/LM_PersonaPurchaseAllocation__c.csv', 'r', encoding='utf-8') as f:
        reader = csv.DictReader(f)
        for row in reader:
            persona_id = row['Persona__c']
            purchase_id = row['PurchaseCondition__c']
            weight = Decimal(row['Weight__c']) if row['Weight__c'] else Decimal('0')
            allocations_by_persona[persona_id].append((purchase_id, weight, None))

    # Read purchase conditions to get dates
    purchase_dates = {}
    with open(f'{script_dir}/LM_ProductLicensePurchaseCondition__c.csv', 'r', encoding='utf-8') as f:
        reader = csv.DictReader(f)
        for row in reader:
            purchase_id = row['Id']
            purchase_date = parse_date(row['PurchaseDate__c'])
            purchase_dates[purchase_id] = purchase_date

    # Rebuild allocations with dates
    for persona_id in allocations_by_persona:
        allocations_by_persona[persona_id] = [
            (p_id, w, purchase_dates.get(p_id))
            for p_id, w, _ in allocations_by_persona[persona_id]
        ]

    # Read existing assignments
    assignments_by_license = defaultdict(list)
    rows = []
    with open(f'{script_dir}/LM_ProductLicenseUserAssignment__c.csv', 'r', encoding='utf-8') as f:
        reader = csv.DictReader(f)
        fieldnames = reader.fieldnames
        for row in reader:
            rows.append(row)
            license_id = row['ProductLicense__c']
            assignments_by_license[license_id].append(row)

    # Generate 120 synthetic HVS assignments (brief Step 5)
    hvs_license_id = 'a03DK00000ZZWHVSYAH'
    hvs_license_name = 'Sales Engagement (HVS) - Enterprise Edition'

    # Generate synthetic HVS users
    import random
    random.seed(42)

    fake_users = [
        f"hvs.user{i:03d}@example.com" for i in range(1, 121)
    ]

    starting_id = 90000
    for i, username in enumerate(fake_users):
        is_active = 'true' if random.random() < 0.7 else 'false'
        # Generate plausible last login dates (mix of recent and older)
        if is_active == 'true' and random.random() < 0.8:
            days_ago = random.randint(1, 180)
            last_login_date = f"2024-{random.randint(5, 11):02d}-{random.randint(1, 28):02d}T12:00:00.000Z"
        else:
            last_login_date = ''

        hvs_row = {
            'Id': f'a02DK00000HVS{starting_id + i}',
            'IsActive__c': is_active,
            'LastLoginDate__c': last_login_date,
            'Name': f'PLUN-9{starting_id + i}',
            'ProductLicense__c': hvs_license_id,
            'ProductLicense__r.Name': hvs_license_name,
            'UniqueConstraint__c': f'{username}|{hvs_license_name}',
            'Username__c': username
        }
        rows.append(hvs_row)
        assignments_by_license[hvs_license_id].append(hvs_row)

    # Sort assignments by Id within each license (deterministic sort)
    for license_id in assignments_by_license:
        assignments_by_license[license_id].sort(key=lambda x: x['Id'])

    # Stamp each license's assignments
    stamped_count = 0
    null_count = 0
    purchase_buckets = set()

    for license_id, license_assignments in assignments_by_license.items():
        persona_id = license_to_persona.get(license_id)
        allocations = allocations_by_persona.get(persona_id, []) if persona_id else []

        sorted_ids = [a['Id'] for a in license_assignments]
        purchase_ids = allocate(sorted_ids, allocations)

        for assignment, purchase_id in zip(license_assignments, purchase_ids):
            assignment['Persona__c'] = persona_id or ''
            assignment['PurchaseCondition__c'] = purchase_id or ''
            if purchase_id:
                stamped_count += 1
                purchase_buckets.add(purchase_id)
            else:
                null_count += 1

    # Write back with new columns
    new_fieldnames = list(fieldnames) + ['PurchaseCondition__c', 'Persona__c']

    with open(f'{script_dir}/LM_ProductLicenseUserAssignment__c.csv', 'w', encoding='utf-8', newline='') as f:
        writer = csv.DictWriter(f, fieldnames=new_fieldnames)
        writer.writeheader()
        for row in rows:
            writer.writerow(row)

    print(f"✓ Stamped {stamped_count} assignments across {len(purchase_buckets)} distinct purchase conditions")
    print(f"✓ {null_count} assignments left null (no purchase condition)")
    print(f"✓ Total rows: {len(rows)} (including {len(assignments_by_license.get(hvs_license_id, []))} synthetic HVS)")

    # Verify CRM Analytics stamping
    crma_license_id = 'a03DK00000ZZWfgYAH'
    crma_assignments = assignments_by_license.get(crma_license_id, [])
    crma_stamped = sum(1 for a in crma_assignments if a.get('PurchaseCondition__c'))
    print(f"✓ CRM Analytics: {crma_stamped}/{len(crma_assignments)} assignments stamped")

    # Verify HVS stamping
    hvs_assignments = assignments_by_license.get(hvs_license_id, [])
    hvs_stamped = sum(1 for a in hvs_assignments if a.get('PurchaseCondition__c'))
    print(f"✓ HVS: {hvs_stamped}/{len(hvs_assignments)} assignments stamped")


if __name__ == '__main__':
    main()
