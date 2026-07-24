# Project Coding Conventions you MUST follow

## Code Style
- Follow PEP 8 style guide to ensure readability and consistency.
  - **Link**: [PEP 8 – Style Guide for Python Code](https://www.python.org/dev/peps/pep-0008/)
- Use 4 spaces for indentation.
- Use snake_case for functions/variables, PascalCase for classes, UPPER_CASE for constants.
- Use **Black** for automated code formatting.
  - **Link**: [Black Code Formatter](https://black.readthedocs.io/en/stable/)
- Use **Flake8** for linting.
  - **Link**: [Flake8](https://flake8.pycqa.org/en/latest/)

## Documentation
- Include docstrings for all modules, classes, and functions following PEP 257.
  - **Link**: [PEP 257 – Docstring Conventions](https://www.python.org/dev/peps/pep-0257/)
- Use type hints for function parameters and return values.

## Imports and Dependencies
- Group imports: standard library, third-party, local modules.
- Prefer specific imports over wildcard imports.
- Use requirements.txt and requirements-dev.txt for managing dependencies.

## Error Handling and Logging
- Use try-except blocks and log exceptions with the `logging` module.
- Use appropriate logging levels (DEBUG, INFO, WARNING, ERROR, CRITICAL).

## Data and Models
- Use dataclasses for model definitions (see `src/models/`).
- Implement `to_dict()` and `from_dict()` methods for serialization.

## Project Structure
- Organize code in `src` directory with subdirectories: `services`, `db/models`, `db/operations`, `handlers`, `hooks`, and `utils`. Adjust as needed.

## Testing and Configuration
- Write unit tests using pytest in the `tests/` directory. Common fixtures defined in `tests/conftest.py`.
  - **Link**: [pytest](https://docs.pytest.org/en/latest/)
- Use environment variables for configuration, storing sensitive info in `.env` files.
- Use `.coveragerc` for configuring test coverage.

### Test Writing Best Practices
- Use descriptive test names that explain the behavior being tested.
- Always use a descriptive one-line docstring for each test function. Use comments for additional context.
- Prefer the `@pytest.mark` decorator for parametrizing tests instead of loops.
- Use `@pytest.fixture` for setting up test data or resources.
- Group related tests in classes for better organization.
- Use `pytest.raises()` to test for expected exceptions.
- Utilize `pytest-mock` for mocking and `freezegun` for time-related tests.
- Use `moto` for mocking AWS services in tests.
- Aim for high test coverage using `pytest-cov`, but prioritize meaningful tests over coverage percentage.
- Use `mypy` with `boto3-stubs[dynamodb]` for static type checking in your test code.

## Philosophical Guidelines
- Adhere to **The Zen of Python** to guide programming practices and decisions.
  - **Link**: [The Zen of Python (PEP 20)](https://www.python.org/dev/peps/pep-0020/)

---

## Project specific conventions and notes
- 

