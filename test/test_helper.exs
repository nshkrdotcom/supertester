ExUnit.start()

# Configure ExUnit for testing the supertester library itself
ExUnit.configure(exclude: [:integration], timeout: 30_000)
