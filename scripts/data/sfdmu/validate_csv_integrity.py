#!/usr/bin/env python3
"""
Validate CSV integrity for SFDMU referential integrity.
"""
import csv
import sys


def validate_csv(file_path):
    """Parse CSV and validate basic structure."""
    try:
        with open(file_path, 'r', encoding='utf-8') as f:
            reader = csv.DictReader(f)
            rows = list(reader)
            if not rows:
                return None, 0, []
            return reader.fieldnames, len(rows), rows
    except Exception as e:
        print(f"✗ Failed to parse {file_path}: {e}")
        sys.exit(1)


def main():
    script_dir = '/Users/tnascimento/dev/sf-license-manager/scripts/data/sfdmu'

    print("=== CSV Structure Validation ===")

    # Validate each CSV
    files = [
        'LM_ProductLicense__c.csv',
        'LM_ProductLicensePersona__c.csv',
        'LM_ProductLicensePurchaseCondition__c.csv',
        'LM_PersonaPurchaseAllocation__c.csv',
        'LM_ProductLicenseUserAssignment__c.csv'
    ]

    data = {}
    for file in files:
        path = f'{script_dir}/{file}'
        headers, count, rows = validate_csv(path)
        if headers is None:
            print(f"✗ {file}: empty file")
            sys.exit(1)
        data[file] = {'headers': headers, 'count': count, 'rows': rows}
        print(f"✓ {file}: {len(headers)} columns, {count} rows")

    print("\n=== Referential Integrity ===")

    # Collect all IDs
    license_ids = {row['Id'] for row in data['LM_ProductLicense__c.csv']['rows']}
    persona_ids = {row['Id'] for row in data['LM_ProductLicensePersona__c.csv']['rows']}
    purchase_ids = {row['Id'] for row in data['LM_ProductLicensePurchaseCondition__c.csv']['rows']}

    print(f"✓ ProductLicense IDs: {len(license_ids)}")
    print(f"✓ Persona IDs: {len(persona_ids)}")
    print(f"✓ PurchaseCondition IDs: {len(purchase_ids)}")

    # Validate allocation junction references
    errors = []
    for row in data['LM_PersonaPurchaseAllocation__c.csv']['rows']:
        persona = row['Persona__c']
        purchase = row['PurchaseCondition__c']
        if persona and persona not in persona_ids:
            errors.append(f"Junction row references unknown Persona__c: {persona}")
        if purchase and purchase not in purchase_ids:
            errors.append(f"Junction row references unknown PurchaseCondition__c: {purchase}")

    if errors:
        print("✗ Junction referential integrity errors:")
        for e in errors:
            print(f"  - {e}")
        sys.exit(1)
    else:
        print(f"✓ Junction: all {data['LM_PersonaPurchaseAllocation__c.csv']['count']} rows reference valid IDs")

    # Validate assignment references
    errors = []
    stamped_persona = 0
    stamped_purchase = 0
    for row in data['LM_ProductLicenseUserAssignment__c.csv']['rows']:
        persona = row.get('Persona__c', '')
        purchase = row.get('PurchaseCondition__c', '')
        if persona:
            stamped_persona += 1
            if persona not in persona_ids:
                errors.append(f"Assignment {row['Id']} references unknown Persona__c: {persona}")
        if purchase:
            stamped_purchase += 1
            if purchase not in purchase_ids:
                errors.append(f"Assignment {row['Id']} references unknown PurchaseCondition__c: {purchase}")

    if errors:
        print("✗ Assignment referential integrity errors:")
        for e in errors[:10]:  # Show first 10
            print(f"  - {e}")
        if len(errors) > 10:
            print(f"  ... and {len(errors) - 10} more")
        sys.exit(1)
    else:
        print(f"✓ Assignments: {stamped_persona} persona refs, {stamped_purchase} purchase refs, all valid")

    print("\n=== Summary ===")
    print(f"✓ All CSVs parsed successfully")
    print(f"✓ All referential integrity checks passed")
    print(f"✓ Ready for SFDMU load")


if __name__ == '__main__':
    main()
