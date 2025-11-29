# Makefile for DragonFly BSD Kernel Documentation

.PHONY: help install serve build clean

# Default target
help:
	@echo "DragonFly BSD Kernel Documentation"
	@echo ""
	@echo "Available targets:"
	@echo "  install    - Install MkDocs and dependencies"
	@echo "  serve      - Run local development server (http://127.0.0.1:8000)"
	@echo "  build      - Build static HTML site to site/ directory"
	@echo "  clean      - Remove generated site/ directory"
	@echo ""
	@echo "Quick start:"
	@echo "  make install   # First time setup"
	@echo "  make serve     # Preview documentation"

# Install MkDocs and Material theme
install:
	@echo "Installing MkDocs and Material theme..."
	pip install --user mkdocs mkdocs-material
	@echo ""
	@echo "Installation complete!"
	@echo "Run 'make serve' to start the development server."

# Run local development server
serve:
	@echo "Starting MkDocs development server..."
	@echo "Documentation will be available at http://127.0.0.1:8000"
	@echo "Press Ctrl+C to stop the server."
	mkdocs serve

# Build static HTML site
build:
	@echo "Building static HTML site..."
	mkdocs build
	@echo ""
	@echo "Build complete! Site generated in site/ directory."

# Clean generated files
clean:
	@echo "Removing generated site..."
	rm -rf site/
	@echo "Clean complete!"
