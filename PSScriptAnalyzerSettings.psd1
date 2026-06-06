@{
    # PSScriptAnalyzer configuration used by CI (and picked up by editors).
    Severity = @('Error', 'Warning')

    # Rules excluded because the flagged pattern is intentional in this codebase:
    ExcludeRules = @(
        # SecureStrings are deliberately constructed from already-known plaintext:
        #   * Public/Update-DATApplicationCommands.ps1 re-secures a BIOS password
        #     parsed out of an existing install command (the plaintext already
        #     exists; converting to SecureString is the mitigation).
        #   * Tests build throwaway fake secrets for unit tests.
        # The shipping public API still accepts SecureString parameters.
        'PSAvoidUsingConvertToSecureStringWithPlainText'
    )
}
