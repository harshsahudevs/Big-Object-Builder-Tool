# Big Object Builder Tool

A no-code Salesforce app for creating and managing Big Objects. Define a Big Object with point-and-click, map data into it, and archive and retrieve records, all from one place.

> Personal project. Not an official Salesforce product.

## Why this exists

Big Objects are built for very large data volumes, but getting started is harder than it should be. Creating one usually means writing metadata by hand and making Metadata API calls, which keeps many teams from using them at all.

This tool puts those steps behind a guided interface, so a Big Object can be created without writing code.

## Features

- **No-code creation:** define a Big Object (fields and index) through a point-and-click UI instead of writing metadata and Metadata API calls.
- **Data mapping:** map data from [FILL: source, e.g. standard or custom objects] into a Big Object.
- **Archive:** store data in a Big Object for long-term retention.
- **Retrieve:** retrieve records from big objects.
- **Modular design:** creation, mapping, archive and retrieval are separate modules inside one application. [FILL: confirm]


## How it works

The app is built with Apex, Lightning Web Components (LWC) and the Metadata API.


## Getting started

### Prerequisites

- [Salesforce CLI](https://developer.salesforce.com/tools/salesforcecli)
- Node.js (for linting and LWC Jest tests)
- VS Code with the Salesforce Extension Pack (optional)
- A Salesforce org. A free [Developer Edition](https://developer.salesforce.com/signup) works.

### Setup

```bash
git clone https://github.com/harshsahudevs/Big-Object-Builder-Tool.git
cd Big-Object-Builder-Tool
npm install
sf org login web --alias bigobject-dev
sf project deploy start --target-org bigobject-dev
```




## Good to know

- The index of a Big Object cannot be changed after the object is created, so plan your index fields before deploying.


## Project structure

```
force-app/main/default/   Apex classes, LWC and other metadata
config/                   Scratch org definition
scripts/                  Helper scripts
sfdx-project.json         Project manifest
```

## Testing

```bash
npm run test:unit
npm run lint
sf apex run test --test-level RunLocalTests --target-org bigobject-dev --code-coverage --result-format human
```

## Tech stack

Apex, Lightning Web Components, Salesforce Metadata API, Salesforce DX, Jest, ESLint, Prettier.

## Author

Harsh Sahu - [LinkedIn](https://www.linkedin.com/in/harshsahudev/)

