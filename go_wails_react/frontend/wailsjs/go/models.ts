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

}

