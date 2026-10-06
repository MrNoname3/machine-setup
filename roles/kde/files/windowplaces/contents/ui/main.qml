import QtQuick
import QtCore
import org.kde.kwin

// Gives each window named in the "targets" setting ([{"class": …, "title": …}],
// matched exactly) the place, size and keep-above state it had when such a
// window last closed.
Item {
    id: root

    readonly property var targets: JSON.parse(KWin.readConfig("targets", "[]"))

    Settings {
        id: store
        location: StandardPaths.writableLocation(StandardPaths.GenericConfigLocation) + "/kwinwindowplacesrc"
        property string places: "{}"
    }

    function targetKey(window) {
        for (const target of targets) {
            if (window.resourceClass === target["class"] && window.caption === target.title) {
                return target["class"] + "/" + target.title;
            }
        }
        return "";
    }

    function restore(window, key) {
        const place = JSON.parse(store.places)[key];
        if (place) {
            window.frameGeometry = Qt.rect(place.x, place.y, place.width, place.height);
            window.keepAbove = place.keepAbove;
        }
    }

    function remember(window, key) {
        const places = JSON.parse(store.places);
        const geometry = window.frameGeometry;
        places[key] = { x: geometry.x, y: geometry.y, width: geometry.width, height: geometry.height,
                        keepAbove: window.keepAbove };
        store.places = JSON.stringify(places);
    }

    function track(window) {
        const key = targetKey(window);
        if (key === "") {
            return false;
        }
        restore(window, key);
        window.closed.connect(() => remember(window, key));
        return true;
    }

    // A window can get its title only after it opens.
    function add(window) {
        if (!window.normalWindow || track(window)) {
            return;
        }
        const onCaption = () => {
            if (track(window)) {
                window.captionChanged.disconnect(onCaption);
            }
        };
        window.captionChanged.connect(onCaption);
        window.closed.connect(() => window.captionChanged.disconnect(onCaption));
    }

    Connections {
        target: Workspace
        function onWindowAdded(window) {
            root.add(window);
        }
    }

    Component.onCompleted: {
        for (const window of Workspace.stackingOrder) {
            add(window);
        }
    }
}
