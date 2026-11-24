export namespace backend {
	
	export class ColumnSchema {
	    name: string;
	    type: string;
	    null: string;
	
	    static createFrom(source: any = {}) {
	        return new ColumnSchema(source);
	    }
	
	    constructor(source: any = {}) {
	        if ('string' === typeof source) source = JSON.parse(source);
	        this.name = source["name"];
	        this.type = source["type"];
	        this.null = source["null"];
	    }
	}
	export class Filter {
	    column: string;
	    value: any;
	
	    static createFrom(source: any = {}) {
	        return new Filter(source);
	    }
	
	    constructor(source: any = {}) {
	        if ('string' === typeof source) source = JSON.parse(source);
	        this.column = source["column"];
	        this.value = source["value"];
	    }
	}
	export class QueryResult {
	    columns: string[];
	    rows: any[];
	    more: boolean;
	
	    static createFrom(source: any = {}) {
	        return new QueryResult(source);
	    }
	
	    constructor(source: any = {}) {
	        if ('string' === typeof source) source = JSON.parse(source);
	        this.columns = source["columns"];
	        this.rows = source["rows"];
	        this.more = source["more"];
	    }
	}
	export class TableHits {
	    table: string;
	    rows: number;
	
	    static createFrom(source: any = {}) {
	        return new TableHits(source);
	    }
	
	    constructor(source: any = {}) {
	        if ('string' === typeof source) source = JSON.parse(source);
	        this.table = source["table"];
	        this.rows = source["rows"];
	    }
	}

}

export namespace main {
	
	export class AppInfo {
	    version: string;
	    build: string;
	    buildDate: string;
	    go: string;
	    wails: string;
	    duckdb: string;
	    access: string;
	
	    static createFrom(source: any = {}) {
	        return new AppInfo(source);
	    }
	
	    constructor(source: any = {}) {
	        if ('string' === typeof source) source = JSON.parse(source);
	        this.version = source["version"];
	        this.build = source["build"];
	        this.buildDate = source["buildDate"];
	        this.go = source["go"];
	        this.wails = source["wails"];
	        this.duckdb = source["duckdb"];
	        this.access = source["access"];
	    }
	}
	export class ConversionResult {
	    done: boolean;
	    saved: string;
	
	    static createFrom(source: any = {}) {
	        return new ConversionResult(source);
	    }
	
	    constructor(source: any = {}) {
	        if ('string' === typeof source) source = JSON.parse(source);
	        this.done = source["done"];
	        this.saved = source["saved"];
	    }
	}
	export class DisplayWarning {
	    text: string;
	    missing: string;
	    distro: string;
	    command: string;
	    help: string;
	
	    static createFrom(source: any = {}) {
	        return new DisplayWarning(source);
	    }
	
	    constructor(source: any = {}) {
	        if ('string' === typeof source) source = JSON.parse(source);
	        this.text = source["text"];
	        this.missing = source["missing"];
	        this.distro = source["distro"];
	        this.command = source["command"];
	        this.help = source["help"];
	    }
	}

}

