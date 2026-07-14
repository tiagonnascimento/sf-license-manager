/**
 * Chunked truncation of LM_ProductLicenseUserAssignment__c ahead of a materialization reload.
 *
 * A single `delete [SELECT Id FROM ...]` cannot truncate a large table: the implicit query counts
 * every row against the 50,000 query-row governor limit, so any materialization over ~50k rows
 * throws "Too many query rows: 50001". This queueable deletes one bounded chunk per transaction and
 * re-enqueues itself until the table is empty, then chains LM_AssignmentGenerationBatch to reload.
 *
 * Each execute() runs in its own transaction with fresh governor limits, so the chain scales to any
 * row count in production and sandboxes. This is the entry point for a full reload — do NOT call the
 * batch directly, as it no longer truncates (see LM_AssignmentGenerationBatch.start()).
 *
 * SCRATCH/DEVELOPER-EDITION CAVEAT: those org types cap chained-queueable depth at 5. With a 10k DML
 * limit per transaction that bounds a single reload to ~50k pre-existing rows before hitting
 * "Maximum stack depth has been reached." Production and sandboxes have no such depth cap. If the
 * scratch/DE ceiling ever becomes a real constraint for local testing, switch truncation to a
 * Database.Batchable (QueryLocator streams past 50k with no depth limit) and chain the reload in
 * finish().
 */
public with sharing class LM_AssignmentPurgeQueueable implements Queueable {
  // Bounded well under the 50k query-row and 10k DML-row limits, leaving headroom for the
  // master-detail rollup recalculation the delete triggers on LM_ProductLicense__c.
  @TestVisible
  private static final Integer DEFAULT_CHUNK_SIZE = 10000;

  private final Integer chunkSize;

  // Test hooks: chaining is suppressed under Test.isRunningTest() (chained queueables and batches
  // do not run in test context), so tests assert intent via these flags instead.
  @TestVisible
  private static Boolean purgeRechained = false;
  @TestVisible
  private static Boolean reloadEnqueued = false;

  public LM_AssignmentPurgeQueueable() {
    this(DEFAULT_CHUNK_SIZE);
  }

  public LM_AssignmentPurgeQueueable(Integer chunkSize) {
    this.chunkSize = (chunkSize == null ||
      chunkSize <= 0)
      ? DEFAULT_CHUNK_SIZE
      : chunkSize;
  }

  public void execute(QueueableContext ctx) {
    List<LM_ProductLicenseUserAssignment__c> chunk = [
      SELECT Id
      FROM LM_ProductLicenseUserAssignment__c
      LIMIT :chunkSize
    ];
    if (!chunk.isEmpty()) {
      delete chunk;
    }

    // A full chunk means the LIMIT was hit, so more rows remain — re-chain this queueable to delete
    // the next chunk in a fresh transaction. A short (or empty) chunk means the table is now clear,
    // so hand off to the reload batch. No extra count/probe query needed.
    if (chunk.size() == chunkSize) {
      purgeRechained = true;
      if (!Test.isRunningTest()) {
        System.enqueueJob(new LM_AssignmentPurgeQueueable(chunkSize));
      }
    } else {
      reloadEnqueued = true;
      if (!Test.isRunningTest()) {
        Database.executeBatch(new LM_AssignmentGenerationBatch(), 1);
      }
    }
  }
}
