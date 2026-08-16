//gbc_fgljp js extension/add-in for fgljp
//its added after gbc.js in index.html by fgljp
'use strict';
window.fgljp = new Object;
window.fgljp.navman=null;
console.log("gbc_fgljp begin");
(function() {
  var _sessId=null;
  var _numRequest=1;
  var _cmdCount=0;
  var _source=null;
  var _useSSE=false; //use Server Side Events
  var _verbose=false;
  var _proto=1; //UR protocol version, ist set to 2 for GBC>=4.00
  var _procId=null;
  var _isBrowser=true;
  var _metaSeen=true;
  var urlog=function(s){};
  var mylog=function(s){};
  var tryJSONs=function(data){};
  var _debug=false;
  var _fcd_timer=null;
  var _sse_timer=null;
  var _empty_trials=0; //number of attempts to get SSE events if we have no procIds
  var _isGBC4 = true;
  var _isGBC5 = true;
  var _gbcMajor = 1;
  var _gbcMinor = 0;
  var _gbcPatchLevel = 0;
  var _gbcMinor_PL = ""; //Minor + patchLevel
  var _procIds = new Map;
  var _lastMeta = null;
  function checkQueryParams() {
    var usp=new URLSearchParams(window.location.search);
    var useSSE=usp.get("useSSE");
    var verbose=usp.get("verbose");
    _useSSE= (useSSE=="1") ?true:false;
    _verbose= (verbose=="1") ?true:false;
    _proto=window.gbcWrapper.protocolVersion;
    if (window.gbcWrapper.isPlatformTypeBrowser) {
      _isBrowser=window.gbcWrapper.isPlatformTypeBrowser()
    } else if (window.gbcWrapper.isBrowser) {
      _isBrowser=window.gbcWrapper.isBrowser();
    }
    mylog("_useSSE:"+_useSSE+",_proto:"+_proto+",_isBrowser:"+_isBrowser);
  }
  checkQueryParams();
  if (_debug || _verbose) {
    urlog=function(s) {
      console.log("[UR] "+s);
      //alert(s.replace(/"/g, "'"));
    }
    mylog=function(s) {
      console.log(s);
    }
    tryJSONs=function( data ) {
      if (typeof data == "object" ) {
        return JSON.stringify(data);
      }
      return data;
    }
  }
  function myalert(txt) {
    console.log("alert:"+txt);
    //alert(txt);
  }
  function myassert(expr,txt) {
    if (expr===false) {
      myalert(txt);
      console.trace();
    }
  }
  function getCurrentSession() {
    const ss=window.gbc.SessionService;
    return ss.getCurrent();
  }
  function getCurrentApp() {
    const sess=getCurrentSession();
    return sess.getCurrentApplication();
  }
  //override gbc's onbeforeunload
  window.onbeforeunload = function() {
    if (_procIds.size > 0 || getCurrentApp()) {
      return "Really leave page ?"; //note: the text isn't displayed anymore in newer browsers
    }
  }
  function getNode(id, app) {
    const theApp=Boolean(app)?app:getCurrentApp();
    return theApp.model.getNode(id);
  }
  function getProcId(app) {
    const node0=getNode(0,app);
    return node0.attribute("procId");
  }
  function isProcessing(app) {
    const node0=getNode(0,app);
    return node0.attribute("runtimeStatus")=="processing";
  }
  function isInteractive(app) {
    const node0=getNode(0,app);
    return node0.attribute("runtimeStatus")=="interactive";
  }
  function getAppName(app) {
    const node0=getNode(0,app);
    return node0.attribute("name");
  }
  function elForTextInt(el,text) {
    if (!el) { return null; }
    if (el.nodeType==3 && text == el.textContent) {
      return el;
    }
    const childNodes = el.childNodes;
    for (let i=0;i<childNodes.length;i++) {
      var cEl=elForTextInt(childNodes[i],text);
      if (cEl!==null) {
        return cEl;
      }
    }
    return null;
  }
  function elForText(text) {
    const el=elForTextInt(document.body,text);
    if (el!==null) {
      return el.parentElement; //the node containing the text
    }
    return null;
  }
  fgljp.elForText=elForText;
  function ancientScrollX() {
    var t;
    return (((t = document.documentElement) || (t = document.body.parentNode)) && typeof t.ScrollLeft == 'number' ? t : document.body).ScrollLeft;
  }
  function ancientScrollY() {
    var t;
    return (((t = document.documentElement) || (t = document.body.parentNode)) && typeof t.ScrollTop == 'number' ? t : document.body).ScrollTop;
  }
  function getScrollX() {
    return window.scrollX !== undefined ? window.scrollX :
          ( window.pageXOffset !== undefined ? window.pageXOffset : ancientScrollX());
  }
  function getScrollY() {
    return window.scrollY !== undefined ? window.scrollY :
          ( window.pageYOffset !== undefined ? window.pageYOffset : ancientScrollY());
  }
  function eventInit() {
    return { bubbles: true,
           view: window,
           cancelable: true };
  }
  function sendQAMouseEvent(el) {
    var r = el.getBoundingClientRect();
    var whalf = r.width/2;
    var hhalf = r.height/2;
    var x=r.left+whalf;
    var y=r.top+hhalf;
    var screenX = getScrollX() + whalf;
    var screenY = getScrollY() + hhalf;
    var el2=document.elementFromPoint(x,y);
    if (el2&&el2!=el) { //check if a sub el is in the middle
      mylog("!!!el2:"+el2.tagName);
    }
    var evInit = eventInit();
    evInit.clientX = whalf;
    evInit.clientY = hhalf;
    evInit.screenX = screenX;
    evInit.clientY = screenY;
    var mouseEv=new MouseEvent("click", evInit );
    el.dispatchEvent(mouseEv);
  }
  function getNavMan() {
    var sess=getCurrentSession();
    var nav=sess.getNavigationManager();
    return nav;
  }
  function raiseProcId(procId) {
    var nav=getNavMan();
    try {
      nav.__raiseProcId(procId);
    } catch(err) {
      myalert("raiseProcId: "+err.message);
    }
  }
  function appFromProcId(procId) {
    var sess=getCurrentSession();
    var nav=sess.getNavigationManager();
    var app=null;
    try {
      app=nav.__appFromProcId(procId);
    } catch(err) {
      myalert("appFromProcId: "+err.message);
    }
    return app;
  }
  function procIdShort(procId) {
    var idx=procId.indexOf(":");
    return procId.substring(idx+1);
  }
  var _xmlH = null;
  function getAJAXAnswer() {
    //mylog("getAJAXAnswer readyState:"+_xmlH.readyState+",status:"+_xmlH.status);  
    if (_xmlH == null) {
      //alert("no _xmlH  in getAJAXAnswer");
      return;
    }
    if (_xmlH.readyState != 4 ) {return;}
    if (_xmlH.status != 200) {
      mylog("AJAX status:"+_xmlH.status);
      _xmlH=null;
      return;
    }
    var responseText=_xmlH.responseText;
    if (_sessId==null) {
      _sessId=_xmlH.getResponseHeader("X-FourJs-Id");
      var headers = _xmlH.getAllResponseHeaders().toLowerCase();
      mylog("got session id:"+_sessId+",headers:"+headers);
      //_wcPath=_xmlH.getResponseHeader("X-Fourjs-Webcomponent");
      var srv=_xmlH.getResponseHeader("X-Fourjs-Server");
      mylog("srv:"+srv); 
      if (_useSSE && _source == null) {
        var url=getUrlBase() + "/ua/sse/"+encodeURIComponent(_sessId)+"?appId=0";
        addEventSource(url); 
      }
    }
    var req=_xmlH;
    _xmlH=null;
    /*
    if (req.getResponseHeader("X-FourJs-Closed")=="true") {
      mylog("X-FourJs-Closed seen");
      window.document.body.innerHTML="X-FourJs-Closed:The Application ended";
      return;
    }*/
    if (responseText.length==0) {
      if (!_useSSE) { //SSE: we come back from POST without any answer
        mylog("getAJAXAnswer:!!!!!!!!!!!!!!!!NO TEXT!!!!!!!!!!!!!!!!!!");
      }
    } else {
      if (_useSSE) {
        myalert("getAJAXAnswer: unwanted responseText:"+responseText);
        return;
      }
      /* following the 'classic' GAS protocol */
      if (responseText.length>1000) {
        mylog("getAJAXAnswer:"+responseText.substring(0,800)+" > ... < "+responseText.substr(-200));
      } else {
        mylog("getAJAXAnswer:"+responseText);
      }
      try {
        if (!_metaSeen) {
          _metaSeen=true;
          myMeta(responseText);
        } else {
          emitReceive(responseText);
        }
      } catch (err) {
        mylog("error: "+err.message+",stack: "+err.stack);
        alert("error: "+err.message+",stack: "+err.stack);
      }
    }
  }
  function getUrlBase() {
    var l=window.location;
    var baseurl=l.protocol+"//"+l.host;
    return baseurl;
  }
  function getCloseUrl() {
    //GBC4: we use _sessId
    var id=_sessId?_sessId:getCurrentSession().getSessionId();
    var sessId = encodeURIComponent(id);
    //use an fgljp specific URL
    return getUrlBase() + "/ua/fgljp_close/"+sessId;
  }
  //computes the necessary URL when running via GAS protocol
  function getUrl() {
    var usp=new URLSearchParams(window.location.search);
    var appName=encodeURIComponent(usp.get("app"));
    var appId = (_procId !== null && _procId!=_sessId ) ? encodeURIComponent(_procId) : "0";
    var sessId = encodeURIComponent(_sessId)
    var url=getUrlBase()+
      ((_sessId!==null)?
       "/ua/sua/"+sessId+"?appId="+appId+"&pageId="+_numRequest++:
       "/ua/r/"+appName+"?ConnectorURI=&Bootstrap=done");
    mylog("url:"+url);
    return url;
  }
  //sends request via AJAX , in SSE mode the POST doesn't get a result back
  //instead the SSE events get any VM protocol data
  function sendAjax(events,what,close) {
    if (_xmlH!=null) {
      var req=_xmlH;
      mylog("abort _xmlH with: "+req.URL+","+req.EVENTS+","+req.WHAT);
      _xmlH.onreadystatechange = null;
      _xmlH.abort();
    }
    _xmlH = new XMLHttpRequest();
    //alert("sendAjax "+events+what);
    var req=_xmlH;
    var url=(close===true)?getCloseUrl():getUrl();
    req.open(what,url);
    req.URL=url;
    req.EVENTS=events;
    req.WHAT=what;
    req.setRequestHeader("Content-type","text/plain");
    req.setRequestHeader("Pragma","no-cache");
    req.setRequestHeader("Cache-Control","no-store, no-cache, must-revalidate");
    req.onreadystatechange = getAJAXAnswer;
    mylog('sendAjax:'+String(what)+" ev:"+events.substring(0,events.length-1)+" to:"+url);
    req.send(what=="POST"?events:undefined);
  }
  
  function sendPOST(events,procId) {
    if (Boolean(procId)) {
      _procId=procId;
    }
    //setProcIdCookie(procId,"sendPOST");
    sendAjax(events.trim()+"\n","POST");
    _procId=null;
  }
  function getClickableGBCEl(el,text) {
    //walks up the dom hierarchy to find GBC assets and to
    //check if there isn't a "disabled" class tag
    if (!el) {
      return null;
    } else  if (el.classList.contains("disabled")) {
      if (el.getAttribute("interruptable-active")=="interruptable-active") {
        return el;
      }
      console.warn("disabled class found for text '"+text+"'");
      return null;
    } else if (el.id!="" && el.className.indexOf("gbc_") !== -1) {
      return el;
    }
    return getClickableGBCEl(el.parentElement,text);
  }
  //"formedit" front calls: the GDC has them (the form editor of fglped
  //drives its preview with them), GBC has not. A form design tool showing
  //its form in GBC needs the same thing: mark the element the editor cursor
  //is in, whatever it is - a marker drawn on the element's DOM node also
  //covers what a presentation style cannot reach, such as a column of a
  //table that has no rows yet.
  //Same call as the GDC one:
  //  CALL ui.Interface.frontCall("formedit","setselectednodes",[id],[])
  //where id is an AUI node id, several ids separated by comma, or "" to
  //clear the marker.
  var _formEditMarked = [];
  var FORMEDIT_CLASS = "fgljp_formedit_selected";
  function addFormEditStyle() {
    if (document.getElementById("fgljp_formedit_style")) {
      return;
    }
    var style = document.createElement("style");
    style.id = "fgljp_formedit_style";
    //outline rather than border: it does not take part in the layout, so
    //marking an element cannot move the form around
    style.textContent = "." + FORMEDIT_CLASS + "{outline:2px solid #ff9800;" +
      "outline-offset:-2px;background-color:rgba(255,152,0,0.18);}";
    document.head.appendChild(style);
  }
  //the node itself may have no widget yet (a TableColumn of an empty table
  //keeps its header, the decoration node below it has nothing on screen), so
  //walk up until something is actually on screen
  function formEditElement(node) {
    var levels = 0;
    while (node && levels < 4) {
      var widget = node.getWidget ? node.getWidget() : null;
      var el = widget && widget.getElement ? widget.getElement() : null;
      if (el) {
        return el;
      }
      node = node.getParentNode ? node.getParentNode() : null;
      levels++;
    }
    return null;
  }
  function formEditClear() {
    for (var i = 0; i < _formEditMarked.length; i++) {
      _formEditMarked[i].classList.remove(FORMEDIT_CLASS);
    }
    _formEditMarked = [];
  }
  //Brings the element within reach before it is marked: an element on a
  //folder page that is not the current one has nothing on screen to mark at
  //all, so the pages it sits on have to be raised first. GBC does that
  //through the controller of the node - PageController.ensureVisible() makes
  //its page current and passes the request on to its own parent, so folders
  //inside folders come out right whatever the depth. Nodes with no
  //controller of their own (the decoration node below a TableColumn) are
  //handled from the nearest ancestor that has one, the way GBC's own
  //visibleId behaviour does it.
  function formEditEnsureVisible(node) {
    var ctrl = null;
    while (node && !ctrl) {
      ctrl = node.getController ? node.getController() : null;
      node = ctrl ? node : (node.getParentNode ? node.getParentNode() : null);
    }
    if (ctrl && ctrl.ensureVisible) {
      ctrl.ensureVisible(false);
    }
  }
  //...and once it is on a visible page, scrolled to. GBC scrolls for the
  //dialog's current field, which a form being looked at does not have.
  function formEditScrollTo(el) {
    if (el.scrollIntoView) {
      el.scrollIntoView({ block: "nearest", inline: "nearest" });
    }
  }
  //The other direction of the form editor contract: while edit mode is on, a
  //click picks the element instead of using the form, and the program is told
  //with the "formeditclick" action - a program that does not declare it is
  //not disturbed by it. It then asks getclickednode() what was hit, which is
  //how an editor can put its cursor on the source of the element clicked.
  //Secondary clicks are left alone: they open the context menu.
  var _formEditOn = false;
  var _formEditClicked = -1;
  var FORMEDIT_ACTION = "formeditclick";
  //A click marks what it hit right away instead of waiting for the program
  //to mark it back: that answer only arrives once the program has told its
  //editor, the editor has moved its cursor and the form has been compiled
  //again for the new cursor position, which is well over a second. If none
  //of that comes back, the marker returns to where it was.
  var FORMEDIT_CONFIRM_MS = 3000;
  var _formEditRevert = null;
  function formEditWidgetTag(el) {
    var widget = window.gbc.WidgetService.getWidgetFromElement(el);
    if (widget && widget.getAUIWidget && widget.getAUIWidget()) {
      widget = widget.getAUIWidget();
    }
    var tag = widget && widget.getAuiTag ? widget.getAuiTag() : null;
    if (tag) {
      return tag;
    }
    //every widget element carries its aui id, so this still works when the
    //element belongs to no widget of its own
    var withId = el && el.closest ? el.closest("[data-aui-id]") : null;
    return withId ? parseInt(withId.dataset.auiId, 10) : null;
  }
  //only what belongs to the form itself is picked: everything around it -
  //the context menu above all, whose entries are chosen with an ordinary
  //click - has to keep working as it does
  function formEditInForm(node) {
    return Boolean(node) &&
      (node.getTag() === "Form" || Boolean(node.getAncestor("Form")));
  }
  function formEditMouse(event) {
    if (!_formEditOn || event.button !== 0 || event.ctrlKey) {
      return;
    }
    var tag = formEditWidgetTag(event.target);
    var app = getCurrentApp();
    var node = tag && app ? getNode(tag, app) : null;
    if (!formEditInForm(node)) {
      return;
    }
    //the form is being looked at, not used: the click does not reach it
    event.preventDefault();
    event.stopPropagation();
    _formEditClicked = tag;
    formEditMarkNow(tag, app);
    app.scheduler.actionVMCommand(null, { actionName: FORMEDIT_ACTION });
  }
  //marks the clicked element and arms the way back, see FORMEDIT_CONFIRM_MS
  function formEditMarkNow(tag, app) {
    var node = app ? getNode(tag, app) : null;
    var el = node ? formEditElement(node) : null;
    if (!el) {
      return;
    }
    var previous = _formEditMarked;
    formEditClear();
    addFormEditStyle();
    el.classList.add(FORMEDIT_CLASS);
    _formEditMarked = [el];
    formEditCancelRevert();
    _formEditRevert = setTimeout(function() {
      _formEditRevert = null;
      mylog("formedit: click was not confirmed, marker goes back");
      formEditClear();
      for (var i = 0; i < previous.length; i++) {
        previous[i].classList.add(FORMEDIT_CLASS);
      }
      _formEditMarked = previous;
    }, FORMEDIT_CONFIRM_MS);
  }
  function formEditCancelRevert() {
    if (_formEditRevert) {
      clearTimeout(_formEditRevert);
      _formEditRevert = null;
    }
  }
  //Only the click is taken, never the mouse press: the browser makes the
  //contextmenu event the default action of the press, so preventing that
  //press is what stops a two finger tap from opening the context menu -
  //ctrl+click survived it only because this leaves ctrl alone. Taking the
  //click is enough to keep it away from the form: GBC hangs its own mouse
  //handling on document.body, below where this listens.
  function formEditListen(on) {
    if (on) {
      document.addEventListener("click", formEditMouse, true);
    } else {
      document.removeEventListener("click", formEditMouse, true);
    }
  }
  function addFormEditFrontCalls(gbc) {
    gbc.FrontCallService.modules.formedit = {
      //edit(<window node id>, 0|1): same call as the GDC one, the window is
      //not needed here - the click is resolved to whatever element it hit
      edit: function(winId, on) {
        var wanted = String(on) === "1" || on === true;
        if (wanted !== _formEditOn) {
          _formEditOn = wanted;
          formEditListen(wanted);
          mylog("formedit.edit: " + (wanted ? "on" : "off"));
        }
        _formEditClicked = -1;
        //leaving or entering edit mode ends whatever a click was waiting for
        formEditCancelRevert();
        return [];
      },
      //the element hit by the last click, -1 when there was none since the
      //last time it was asked
      getclickednode: function() {
        var clicked = _formEditClicked;
        _formEditClicked = -1;
        return [clicked];
      },
      setselectednodes: function(ids) {
        var app = this.getAnchorNode().getApplication();
        //the program says where the marker belongs, so a click that was
        //marked ahead of this has nothing left to go back to
        formEditCancelRevert();
        formEditClear();
        var list = String(ids === null || ids === undefined ? "" : ids)
          .split(",");
        for (var i = 0; i < list.length; i++) {
          var id = parseInt(list[i], 10);
          if (isNaN(id)) {
            continue;
          }
          var node = getNode(id, app);
          if (!node) {
            mylog("formedit.setselectednodes: no node with id " + id);
            continue;
          }
          formEditEnsureVisible(node);
          var el = formEditElement(node);
          if (!el) {
            mylog("formedit.setselectednodes: nothing on screen for id " + id);
            continue;
          }
          addFormEditStyle();
          el.classList.add(FORMEDIT_CLASS);
          _formEditMarked.push(el);
          formEditScrollTo(el);
        }
        return [];
      }
    };
  }
  function addFGLGBCFrontCalls(gbc) {
    gbc.FrontCallService.modules.fgljp = {
      click_on_element_with_text: function(text,xinterval) {
        let interval=parseInt(xinterval);
        if (isNaN(interval) || interval < 300) {
          interval=300;
        }
        var el=elForText(text);
        if (!el) {
          this.runtimeError("Can't find element with text '"+text+"'");
        } else {
          setTimeout(function() {
           let gbcEl=getClickableGBCEl(el.parentElement,text);
           if (gbcEl!==null) {
             sendQAMouseEvent(el);
           } else {
             mylog("TODO: raise error in Genero program");
           }
          }, interval);
          return [];
        }
      }
    }
    fgljp.click_on_element_with_text=window.gbc.FrontCallService.modules.fgljp.click_on_element_with_text;
  }
  function addDebuggerFrontCalls(gbc) {
    gbc.FrontCallService.modules.debugger = {
      setactivewindow: function(procId) {
        var prev=getProcId();
        var prevAppName=getAppName();
        const anchorNode = this.getAnchorNode();
        const thisApp = anchorNode.getApplication();
        const thisProcId = getProcId(thisApp);
        mylog("setactivewindow:"+procId+",prev:"+prev+",prev appname:"+prevAppName);
        if (procId=="current") {
          procId = thisProcId;
          mylog("  set procId to:"+thisProcId);
        }
        if (procId == prev) {
          mylog(" 1no switch needed");
          clearTimeout(_fcd_timer);
          _fcd_timer=null;
        } else {
          if (_fcd_timer) {
            mylog("  _fcd_timer already set:"+_fcd_timer);
          }
          _fcd_timer=setTimeout(function() {
            const curr=getProcId();
            mylog("setactivewindow timer: curr:"+curr+",procId:"+procId);
            if (curr!=procId) {    
              if (curr==thisProcId && thisProcId!=procId && 
                isInteractive(thisApp)) {
                mylog("keep debugger on top");
              } else {
                mylog("raiseProcId:"+procId);
                raiseProcId(procId);
              }
            } else {
              mylog(" 2no switch needed");
            }
          }, 300);
        }
        return [prev];
      },
      getactivewindow: function() {
        //should return the name/procId of the current(topmost) app
        const procId = getProcId();
        mylog("getactivewindow:"+procId+",app:"+getAppName());
        return [procId];
      },
      getcurrentwindow: function() {
         //should return the procId of the debugger context
         const anchorNode = this.getAnchorNode();
         const thisApp = anchorNode.getApplication()
         const procId = getProcId(thisApp);
         const appName = getAppName(thisApp);
         mylog("getcurrentwindow gets procId:"+procId+",name:"+appName);
         return [procId];
      }
    };
    fgljp.setactivewindow=window.gbc.FrontCallService.modules.debugger.setactivewindow;
    fgljp.getactivewindow=window.gbc.FrontCallService.modules.debugger.getactivewindow;
    fgljp.getcurrentwindow=window.gbc.FrontCallService.modules.debugger.getcurrentwindow;
   
  }
  /*
  function setProcIdCookie(procId,where) {
    const cook = "GENERO_PROCID=" + procId + "; Path=/";
    console.info("set procId:%o,where:%o",cook,where);
    document.cookie = cook;
  }
  function setCurrentProcId() {
    try {
      const nav=getNavMan();
      const win=nav.getCurrentWindow();
      if (win) {
        const app=win.getApplication();
        const procId=app.procId;
        _procId = procId;
        setProcIdCookie(procId,"setCurrentProcId");
      }
    } catch(err) {
      console.warn("setCurrentProcId err:%o",err);
    }
  }
  */
  function myMeta(meta) {
    mylog("myMeta:"+meta);
    var obj={nativeResourcePrefix: "___",
             meta:meta,
             forcedURfrontcalls: window.gbcWrapper._forcedURfrontcalls,
             debugMode:1,
             logLevel:_verbose?4:2};
    _lastMeta = meta;
    emitReady(obj);
    addGBCPatches(window.gbc);
  }
  function emitReady(metaobj) {
    //called by GBC
    window.gbcWrapper.URReady = function(o) {
      mylog("URREADY:"+JSON.stringify(o));
      var sess=getCurrentSession();
      sess.addServerFeatures(["ft-lock-file"]);
      var UCName=(_proto==2)? o.content.UCName : o.UCName;
      var UCVersion =(_proto==2)? o.content.UCVersion : o.UCVersion;
      var mobileUI = (_proto==2)? 
         o.content.mobileUI!==undefined? ` {mobileUI "${o.content.mobileUI}"`:"":"";
      var multiColumnSort = (_proto==2)? 
         o.content.multiColumnSort!==undefined? ` {multiColumnSort "${o.content.multiColumnSort}"`:"":"";
      var meta=`meta Client{{name "GBC"} {UCName "${UCName}"} {version "${UCVersion}"} {host "browser"} {encapsulation "0"} {filetransfer "0"}${mobileUI}${multiColumnSort}}\n`;

      myassert(_sessId!=null);
      mylog("meta:",meta);
      _procIds.set(o.procId,_lastMeta);
      mylog("  _procIds:"+[..._procIds.keys()]);
      
      
      _lastMeta = null;
      sendPOST(meta,o.procId);
    }

    //called by GBC
    window.gbcWrapper.childStart = function() {
      urlog("childStart");
    }
    function procIdFromData(data) {
      var procId=(typeof data=="object"&&data.procId)?data.procId:undefined;
      return procId;
    }
    window.gbcWrapper.close = function(data) {
      urlog("gbcWrapper.close:"+tryJSONs(data));
      if (typeof data=="object" && data.procId ) {
        urlog(" delete:"+data.procId+" from:" +[..._procIds.keys()]);
        _procIds.delete(data.procId)
        /*
        if (_procIds.size==0 && _source!==null ) {
          //we try to avoid requesting forever
          setTimeout(function() {
            //look again
            if (_procIds.size==0 && _source!==null ) {
              urlog("  stop SSE after last close");
              _source.close()
              _source=null;
            }
          }, 500);
        }*/
      }
      //setCurrentProcId();
    }
    window.gbcWrapper.interrupt = function(data) {
      urlog("gbcWrapper.interrupt:"+tryJSONs(data));
      sendPOST("interrupt",procIdFromData(data));
    }
    window.gbcWrapper.ping = function() {
      urlog("ping");
    }
    window.gbcWrapper.processing = function(isProcessing) {
      urlog("processing: "+isProcessing);
    }
    window.gbcWrapper.showDebugger = function(data) {
      urlog("window.gbcWrapper.showDebugger:"+tryJSONs(data));
      var url = window.gbc.UrlService.currentUrl();
      url.removeQueryString("app");
      url.removeQueryString("useSSE");
      url.removeQueryString("verbose");
      url.removeQueryString("UR_PLATFORM_TYPE");
      url.removeQueryString("UR_PLATFORM_NAME");
      url.removeQueryString("UR_PROTOCOL_TYPE");
      url.removeQueryString("UR_PROTOCOL_VERSION");
      var s=url.addQueryString("monitor", 1).toString();
      window.open(s);
    }
    window.gbcWrapper.send = function(data, options) {
      urlog("gbcWrapper.send:"+tryJSONs(data)+",options:"+tryJSONs(options));
      if (_source == null) {
        mylog("no source anymore");
        return;
      }
      var d= (_proto==2) ? data.content : data;
      var procId = (_proto==2) ? data.procId: null;
      var events="event _om "+_cmdCount+"{}{"+d+"}\n";
      _cmdCount+=1;
      sendPOST(events,procId);
    }
    window.gbcWrapper._forcedURfrontcalls= {
    "webcomponent": "*",
    "qa": ["startqa", "removestoredsettings", "getattribute", "playeventlist",
           "geterrors", "checktableishighlighted", "clicktablecell",
           "gettablecolumninfo", "gettableattributebyid","getinformation","gettablefocuscolumnrow"]
    //"qa": ["startqa", "removestoredsettings", "getattribute" ]
    };
    //for now: GBC handles all frontcalls
    window.gbcWrapper.isFrontcallURForced=function(moduleName, functionName) {
      return true;
    }
    window.gbcWrapper.frontcall = function(data, callback) {
      mylog("[gURAPI debug] frontcall(" + data + ") "+ callback);
      window._fc_callback=callback;
    };
    //not used for now
    //could be called by fgljp on another SSE channel/other tag
    window.clientfrontCallBack = function(code) {
      var fc=window._fc_callback;
      window._fc_callback=null;
      //we just pass the status here,
      //the real result is sent to the VM if GBC returns to GMI
      var error=null;
      var result="somedummyresult";
      if (code==-2 || code==-3) {
        error="failed"
        result=null;
      }
      fc({status:code ,result:result, error:error});
    }

    //signal metaobj to GBC
    window.gbcWrapper.emit("ready", metaobj);
  }
  window.gbc_fgljp_unload=function() {
    //urlog("!!!!gbc_fgljp_unload unload!!!");
    console.log("!!!!gbc_fgljp_unload unload!!!");
    closeSource();
    //send a single post to the close url to inform fgljb about browser dead
    sendAjax("","POST",true);
  };
  //called by ajax/SSE
  function emitReceive(data, procId) {
    urlog("emitReceive: " + data + ",procId:" + procId);
    var d = (_proto == 2) ? { content : data, procId: procId } : data;
    try {
      window.gbcWrapper.emit("receive", d);
    } catch(err) {
      alert("emitReceive failed:"+err.message);
    }
  }
  function emit_rn0(procId) {
    try {
      emitReceive("om 10000 {{rn 0}}\n",procId);
    } catch (err) {
      mylog("error {{rn 0}}: "+err.message+",stack: "+err.stack);
    }
  }
  //SSE events
  function addEventSource(url) {
    myassert(_source===null);
    var source = new EventSource(url);
    source.addEventListener('open', function(e) {
      mylog("EventSource openened-->");
    });
    source.addEventListener('vmclose', function(e) {
      var procId = e.lastEventId;
      mylog("SSE vmclose:'"+typeof e.data+","+e.data+"',id:"+procId);
      if (_procIds.has(procId)) {
        //ugly hack to force GBC being closed
        emit_rn0(procId);
      }
      if (e.data == "http404" ) {
        mylog("session ended, finally close source");
        closeSource();
      } else {
        reAddSource(url,true);
      }
      /* 
      //tried various gdc native stuff without success to close the app 'natively'
      window.gbcWrapper.emit("destroyEvent", { content: { message : "destroyed" }, procId: procId} );
      try {
        window.gbcWrapper.emit("nativeAction", { name: "close" });
      } catch (err) {
        mylog("error: "+err.message+",stack: "+err.stack);
      }
      try {
        window.gbcWrapper.emit("end", {procId: procId});
      } catch (err) {
        mylog("error: "+err.message+",stack: "+err.stack);
      }
      */
    });
    source.addEventListener('meta', function(e) {
      const procId=e.lastEventId;
      mylog("SSE meta:'"+typeof e.data+","+e.data+"',id:"+procId);
      var data=String(e.data);
      if (_procIds.has(procId)) {
        myalert("  same procId coming in"+procId+",close old one");
        emit_rn0(procId);
      }
      reAddSource(url,false);
      myMeta(data.trim());
    });
    source.addEventListener('retry', function(e) {
      const procId=e.lastEventId;
      console.log("SSE retry:'"+typeof e.data+","+e.data+"',id:"+procId);
      reAddSource(url,false);
    });
    source.addEventListener('message', function(e) {
      var procId = e.lastEventId;
      mylog("SSE msg data:'"+e.data+"',id:"+procId);
      var data=String(e.data);
      reAddSource(url,true);
      if (data && data.length>0 ) {
        if (data.charAt(0)=="[") { //multiple lines...happens in VM http mode without encaps when processing
          var arr=JSON.parse(data);
          for(var i=0;i<arr.length;i++) {
            emitReceive(arr[i],procId);
          }
        } else {
          emitReceive(data,procId);
        }
      }
    });

    source.addEventListener('error', function(e) {
       mylog("err readyState:"+e.target.readyState);
       if (e.target.readyState == EventSource.CLOSED) {
         mylog("EventSource closed");
       }
       mylog(" close SSE due to an error(server not reachable)");
       closeSource();
    });
    _source=source;
    mylog("added eventsource at url:"+url);
    fgljp.reAdd2=function() {
      reAddSource(url,false);
    }
  }
  function closeSource() {
    if (_source) {
      _source.close()
    }
    _source=null;
  }
  function reAddSource(url,checkProcIds) { //needed for firefox: ignores the retry param
    //which means each SSE event causes the SSE listeners to be added again
    mylog("reAddSource: checkProcIds:"+checkProcIds+",size:"+ _procIds.size+",_sse_timer:"+_sse_timer);
    closeSource();
    clearTimeout(_sse_timer);
    _sse_timer=null;
    /*if (false && checkProcIds && _procIds.size==0) {
        _sse_timer=setTimeout(function() {
          if (_empty_trials<10) {
            _empty_trials++;
            mylog("reAddSource : empty trials:"+_empty_trials);
          } else {
            mylog("reAddSource: finally close eventSource");
            return;
          }
          addEventSource(url);
        }, 1000);
        mylog("did set up _sse_timer:"+_sse_timer);
    } else { //reset the counter */
      mylog("clear sse_timer")
      _empty_trials=0;
      addEventSource(url);
    /*}*/
  }
  function myResourcePath(path, nativePrefix, browserPrefix) {
    // if path has a scheme, don't change it
    if (!path || /^(http[s]?|[s]?ftp|data|file|font)/i.test(path)) {
      return path;
    }
    //console.log("myResourcePath path:"+path+",nativePrefix:"+nativePrefix+",browserPrefix:"+browserPrefix+",_procId:"+_procId);
    //var startPath = (browserPrefix ? browserPrefix + "/" : "");
    if (nativePrefix == "webcomponents" ) {
      nativePrefix = "webcomponents/webcomponents";
    }
    var startPath = (nativePrefix ? nativePrefix + "/" : "");
    let returnPath = startPath + path;
    //console.log("returnPath:"+returnPath);
    return returnPath;
  }
  function addGBCPatchesInt(gbc,haveDebuggerFCs) {
    var gbcP=Object.getPrototypeOf(gbc);
    var classes=gbcP.classes;
    if (_isGBC5 && gbcWrapper.wrapResourcePath) {
      gbcWrapper.wrapResourcePath=myResourcePath;
    } else {
      patchWrapResourcePath(classes); //workaround GBC-3240,GBC-3105
    }
    patchSendUpload(classes);
    patchEmbeddedFocusEtiquette(classes);
    if (_isGBC4 && !haveDebuggerFCs) {
      patchNavMan(classes); //add some helpers
    }
    patchFCURForced(gbc);
    addFGLGBCFrontCalls(gbc);
    addFormEditFrontCalls(gbc);
  }
  function patchWrapResourcePath(classes) {
    var VMApplicationP = classes.VMApplication.prototype;
    //wrapResourcePath should mask non conform path symbols such as \ or :
    VMApplicationP.wrapResourcePath = myResourcePath;
  }

  function patchSendUpload(classes) {
    var FileInputWidgetP = classes.FileInputWidget.prototype;
    FileInputWidgetP.send = function(filename, url, callback, errorCallback, progressHandler) {
      var thefile = null;
      var files = this._files ? this._files :
                  this._element.querySelector("form").file.files;
      for (var i = 0; i < files.length; ++i) {
        var file = files[i];
        if (file.name === filename) {
          thefile = file;
          break;
        }
      }
      if (thefile === null ) {
        errorCallback();
        return;
      }
      var request = new XMLHttpRequest();
      request.onload = function(event) {
         callback();
      }.bind(this);
      request.onerror = function() {
         errorCallback();
      };
      request.open("POST", url);
      request.setRequestHeader("Content-Type",thefile.type);
      request.upload.addEventListener("progress", progressHandler.bind(this));
      request.send(thefile);
    }
  }

  //GBC-5995: embedded etiquette hot patch.
  //GBC's restoreVMFocus() does a DOM focus() after every VM round trip
  //without checking document.hasFocus(): running embedded in an iframe
  //(IDE webview, portal page) it steals the keyboard focus from the host
  //page - with ON IDLE polling once per second. Until a fixed GBC ships
  //(and for customized GBCs which can't rebase immediately) we defer the
  //whole restore while the document doesn't own the keyboard and re-arm
  //it once our window gets focused again.
  function patchEmbeddedFocusEtiquette(classes) {
    var FocusService = classes.FocusApplicationService;
    if (!FocusService || !FocusService.prototype.restoreVMFocus) {
      console.warn("patchEmbeddedFocusEtiquette: no FocusApplicationService.restoreVMFocus, skipped");
      return;
    }
    var orig = FocusService.prototype.restoreVMFocus;
    FocusService.prototype.restoreVMFocus = function() {
      if (document.hasFocus()) {
        return orig.apply(this, arguments);
      }
      mylog("restoreVMFocus deferred: document has no focus (GBC-5995)");
      if (!this._fgljpFocusRearm) {
        var self = this;
        self._fgljpFocusRearm = function() {
          window.removeEventListener("focus", self._fgljpFocusRearm);
          self._fgljpFocusRearm = null;
          var app = self._application;
          if (app && !app.isDestroyed() && app.scheduler &&
              app.scheduler.restoreFocusCommand) {
            app.scheduler.restoreFocusCommand();
          }
        };
        window.addEventListener("focus", self._fgljpFocusRearm);
      }
    };
    mylog("patchEmbeddedFocusEtiquette: active (GBC-5995 hot patch)");
  }

  function patchFCURForced(gbc) {
     var fcs=gbc.FrontCallService;
     if (!fcs) {
       console.warn("patchFC no classes.FrontCallService found");
       return;
     }
     if (fcs.isFrontCallURForced) {
       fcs.isFrontCallURForced=function() {
         return true;
       }
     }
  }
  fgljp.patchFCURForced=patchFCURForced;

  function patchNavMan(classes) {
    var navP = classes.VMSessionNavigationManager.prototype;
    navP.__appFromProcId=function(procId) {
       let app = this._applicationLookupByProcId.get(procId);
       //var name = app ? getAppName(app) : "(null)";
       //console.log("__appFromProcId for procId:"+procId+",name:"+name); 
       return app;
    }
    navP.__raiseProcId=function(procId) {
       //ripped from VMSessionNavigationManagers rootWidget.when(context.constants.widgetEvents.click, () => ...
       //it would be preferable if that was a separately callable API
       fgljp.navman=this;
       const app = this.__appFromProcId(procId);
       if (app) {
         app.getUI().syncCurrentWindow();
       }
    }
  }
  /*
  function patchSidebar(classes) {
    var hSideP = classes.ApplicationHostSidebarWidget.prototype;
    hSideP.isAlwaysVisible=function() { //avoid the disturbing sidebar to steal place
      mylog("isAlwaysVisible");
      return false;
    }
    hSideP.updateResize = function(deltaX,absolute) {
      mylog("updateResize:"+deltaX+",absolute:"+absolute);
    }
    hSideP.updateResizeTimer = function() {
      mylog("updateResizeTimer");
    }
    hSideP._onTransitionEnd = function(evt) {
      mylog("_onTransitionEnd");
    }
    hSideP.setDisplayed = function(displayed) {
      mylog("setDisplayed");
    }
    hSideP.getCurrentSize = function() {
      mylog("getCurrentSize");
      return 0;
    }
    hSideP.getSideBarwidth=function() {
      mylog("getSideBarwidth1");
      return 0;
    }
    gbc.HostLeftSidebarService.enableSidebar(false);
    var sss = classes.StoredSettingsService.prototype;
    sss.getSideBarwidth=function() {
      mylog("getSideBarwidth2");
      return 0;
    }
  }
  */
  function addGBCPatches(gbc) {
    try {
      var haveDebuggerFCs=!!gbc.FrontCallService.modules.debugger;
      addGBCPatchesInt(gbc,haveDebuggerFCs);
      if (_isGBC4 && !haveDebuggerFCs) {
        addDebuggerFrontCalls(gbc);
      }
    } catch (err) {
      myalert("addGBCPatches:"+err.message);
    }
  }
  function startWrapper() {
    mylog("gbc_fgljp startWrapper");
    sendAjax("",(_useSSE ? "POST":"GET"));
  }
  function getSessId() {
    return _sessId;
  }
  if (_debug) {
    fgljp.addGBCPatches=addGBCPatches;
    fgljp.startWrapper=startWrapper;
    fgljp.getCurrentSession=getCurrentSession;
    fgljp.getCurrentApp=getCurrentApp;
    fgljp.getNode=getNode;
    fgljp.getProcId=getProcId;
    fgljp.getNavMan=getNavMan;
    fgljp.raiseProcId=raiseProcId;
    fgljp.getSessId=getSessId;
  }
  window.gbc.ThemeService.setValue("theme-sidebar-max-width","100000px");
  //fgljp --hide-chromebar: an embedder (an IDE preview panel, say) wants the
  //vertical space and has its own frame around us.
  //
  //gbc-ChromeBar-show is the switch GBC reads when a session starts, but by
  //the time this script runs the bar can already be there, so it is also
  //removed through MainContainerService as soon as it shows up. That is GBC's
  //own call: it takes the bar out and reports isChromeBarVisible() false, so
  //whatever GBC routes to the chrome goes elsewhere instead of into something
  //merely made invisible with CSS.
  if (/[?&]hidechromebar=1(&|$)/.test(window.location.search)) {
    window.gbc.ThemeService.setValue("gbc-ChromeBar-show", false);
    var _cbTries = 0;
    var _cbTimer = setInterval(function() {
      var mcs = window.gbc.MainContainerService;
      if (mcs && mcs.isChromeBarVisible()) {
        mcs.hideChromeBar();
        mylog("chrome bar hidden (fgljp --hide-chromebar)");
        clearInterval(_cbTimer);
      } else if (++_cbTries > 60) { //~3s, the bar never appeared
        clearInterval(_cbTimer);
      }
    }, 50);
  }
  var ver=window.gbc.version;
  _isGBC4= parseFloat(ver)>=4.0;
  _isGBC5= parseFloat(ver)>=5.0;
  var firstDot= ver.indexOf(".");
  myassert(firstDot>=0);
  _gbcMajor = parseInt(ver.substring(0,firstDot));
  var last = ver.lastIndexOf(".");
  if (firstDot < last) {
    var sub = ver.substring(firstDot+1,last);
    _gbcMinor = parseInt(sub);
    var slice= ver.slice( - (ver.length - last - 1 ));
    _gbcPatchLevel = parseInt(slice);
    _gbcMinor_PL=sub+"."+slice;
  } else {
    var sub = ver.substring(firstDot+1);
    _gbcMinor = parseInt(sub);
  }
  //alert("_gbcMajor:"+_gbcMajor+",_gbcMinor:"+_gbcMinor+",_gbcPatchLevel:"+_gbcPatchLeve+"_gbcMinor_PL:"+_gbcMinor_PL);
  
  if (_isBrowser) {
    window.__gbcDefer = function (start) {//only called in "browser" mode by GBC
      mylog("__gbcDefer called in browser mode,_useSSE:"+_useSSE+",start:"+start);
      mylog("gbc ver:"+window.gbc.version+",_isGBC4:"+_isGBC4);
      if (_useSSE && !_isGBC5) {
        myalert("_useSSE active, not possible to be set in browser mode");
        return;
      }
      addGBCPatches(window.gbc);
      start();
    };
    if (_isGBC5) {
      startWrapper();
    }
  } else {
    startWrapper();
  }
})();
console.log("gbc_fgljp end");
