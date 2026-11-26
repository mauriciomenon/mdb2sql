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
	export class TermHit {
	    term: string;
	    table: string;
	    rows: number;
	
	    static createFrom(source: any = {}) {
	        return new TermHit(source);
	    }
	
	    constructor(source: any = {}) {
	        if ('string' === typeof source) source = JSON.parse(source);
	        this.term = source["term"];
	        this.table = source["table"];
	        this.rows = source["rows"];
	    }
	}
	export class TermsResult {
	    terms: string[];
	    repeated: number;
	    hits: TermHit[];
	    tables: TableHits[];
	    notFound: string[];
	
	    static createFrom(source: any = {}) {
	        return new TermsResult(source);
	    }
	
	    constructor(source: any = {}) {
	        if ('string' === typeof source) source = JSON.parse(source);
	        this.terms = source["terms"];
	        this.repeated = source["repeated"];
	        this.hits = this.convertValues(source["hits"], TermHit);
	        this.tables = this.convertValues(source["tables"], TableHits);
	        this.notFound = source["notFound"];
	    }
	
		convertValues(a: any, classs: any, asMap: boolean = false): any {
		    if (!a) {
		        return a;
		    }
		    if (a.slice && a.map) {
		        return (a as any[]).map(elem => this.convertValues(elem, classs));
		    } else if ("object" === typeof a) {
		        if (asMap) {
		            for (const key of Object.keys(a)) {
		                a[key] = new classs(a[key]);
		            }
		            return a;
		        }
		        return new classs(a);
		    }
		    return a;
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
	    webview: string;
	    mdbtools: string;
	    mdbtoolsSystem: boolean;
	
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
	        this.webview = source["webview"];
	        this.mdbtools = source["mdbtools"];
	        this.mdbtoolsSystem = source["mdbtoolsSystem"];
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

