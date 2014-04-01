//
//  SEEDocumentListWindowController.m
//  SubEthaEdit
//
//  Created by Michael Ehrmann on 18.02.14.
//  Copyright (c) 2014 TheCodingMonkeys. All rights reserved.
//

#if !__has_feature(objc_arc)
#error ARC must be enabled!
#endif

#import "SEEDocumentListWindowController.h"
#import "SEEDocumentListGroupTableRowView.h"

#import "SEENetworkConnectionDocumentListItem.h"
#import "SEENetworkDocumentListItem.h"
#import "SEENewDocumentListItem.h"
#import "SEEToggleRecentDocumentListItem.h"
#import "SEERecentDocumentListItem.h"
#import "SEEOpenOtherDocumentListItem.h"
#import "SEEConnectDocumentListItem.h"

#import "SEEDocumentController.h"
#import "DocumentModeManager.h"

#import "TCMMMPresenceManager.h"
#import "TCMMMSession.h"
#import "TCMMMUserManager.h"
#import "TCMMMUser.h"
#import "TCMMMUserSEEAdditions.h"

#import "SEEConnectionManager.h"
#import "SEEConnection.h"

#import <QuartzCore/QuartzCore.h>

extern int const FileMenuTag;
extern int const FileNewMenuItemTag;

static void *SEENetworkDocumentBrowserEntriesObservingContext = (void *)&SEENetworkDocumentBrowserEntriesObservingContext;

@interface SEEDocumentListWindowController () <NSTableViewDelegate>

@property (nonatomic, weak) IBOutlet NSScrollView *scrollViewOutlet;
@property (nonatomic, weak) IBOutlet NSTableView *tableViewOutlet;

@property (nonatomic, weak) IBOutlet NSObjectController *filesOwnerProxy;
@property (nonatomic, weak) IBOutlet NSArrayController *documentListItemsArrayController;

@property (nonatomic, weak) id otherWindowsBecomeKeyNotifivationObserver;
@property (nonatomic, strong) SEEToggleRecentDocumentListItem *toggleRecentItem;

@end

@implementation SEEDocumentListWindowController

+ (void)initialize {
	if (self == [SEEDocumentListWindowController class]) {
		[[NSUserDefaults standardUserDefaults] registerDefaults:@{@"DocumentListShowRecent": @(YES)}];
	}
}

- (id)initWithWindow:(NSWindow *)window
{
    self = [super initWithWindow:window];
    if (self) {
		self.availableItems = [NSMutableArray array];
		[self reloadAllDocumentSessions];
		[self installKVO];

		__weak __typeof__(self) weakSelf = self;
		self.otherWindowsBecomeKeyNotifivationObserver =
		[[NSNotificationCenter defaultCenter] addObserverForName:NSWindowDidBecomeKeyNotification object:nil queue:nil usingBlock:^(NSNotification *note) {
			__typeof__(self) strongSelf = weakSelf;
			if (note.object != strongSelf.window && strongSelf.shouldCloseWhenOpeningDocument) {
				if (((NSWindow *)note.object).sheetParent != strongSelf.window) {
					if ([NSApp modalWindow] == strongSelf.window) {
						[NSApp stopModalWithCode:NSModalResponseAbort];
					}
					[self close];
				}
			}
		}];
    }
    return self;
}


- (void)dealloc
{
	[self removeKVO];

    [[NSNotificationCenter defaultCenter] removeObserver:self.otherWindowsBecomeKeyNotifivationObserver];

	[self close];
}


#pragma mark -

- (void)windowDidLoad
{
    [super windowDidLoad];

	[self.window setRestorationClass:NSClassFromString(@"SEEDocumentController")];

	NSScrollView *scrollView = self.scrollViewOutlet;
	scrollView.contentView.layer = [CAScrollLayer layer];
	scrollView.contentView.wantsLayer = YES;
	scrollView.contentView.layerContentsRedrawPolicy = NSViewLayerContentsRedrawNever;
	scrollView.wantsLayer = YES;

	NSTableView *tableView = self.tableViewOutlet;
	[tableView setTarget:self];
	[tableView setAction:@selector(triggerItemClickAction:)];
	[tableView setDoubleAction:@selector(triggerItemDoubleClickAction:)];
}


- (IBAction)showWindow:(id)sender {
	self.filesOwnerProxy.content = self;

	// if window is in auto close mode it should not be restored on app restart.
	self.window.restorable = !self.shouldCloseWhenOpeningDocument;

	[super showWindow:sender];
}


- (void)windowWillClose:(NSNotification *)notification
{
	if ([NSApp modalWindow] == notification.object) {
		[NSApp stopModalWithCode:NSModalResponseAbort];
	}

	self.filesOwnerProxy.content = nil;
}


- (NSInteger)runModal
{
	self.filesOwnerProxy.content = self;
	NSInteger result = [NSApp runModalForWindow:self.window];
	return result;
}


#pragma mark - KVO

- (void)installKVO {
	[[SEEConnectionManager sharedInstance] addObserver:self forKeyPath:@"entries" options:0 context:SEENetworkDocumentBrowserEntriesObservingContext];
}

- (void)removeKVO {
	[[SEEConnectionManager sharedInstance] removeObserver:self forKeyPath:@"entries" context:SEENetworkDocumentBrowserEntriesObservingContext];

	if (self.toggleRecentItem) {
		[self.toggleRecentItem removeObserver:self forKeyPath:@"showRecentDocuments"];
	}
}

- (void)observeValueForKeyPath:(NSString *)keyPath ofObject:(id)object change:(NSDictionary *)change context:(void *)context
{
    if (context == SEENetworkDocumentBrowserEntriesObservingContext) {
		[self reloadAllDocumentSessions];

		if (self.toggleRecentItem) {
			[[NSUserDefaults standardUserDefaults] setBool:@(self.toggleRecentItem.showRecentDocuments) forKey:@"DocumentListShowRecent"];
		}
    } else {
        [super observeValueForKeyPath:keyPath ofObject:object change:change context:context];
    }
}

#pragma mark - Content management

- (void)reloadAllDocumentSessions
{
	[self willChangeValueForKey:@"availableItems"];
	{
		NSDictionary *lookupDictionary = [NSDictionary dictionaryWithObjects:self.availableItems forKeys:[self.availableItems valueForKey:@"uid"]];

		[self.availableItems removeAllObjects];

		{
			{
				SEENetworkConnectionDocumentListItem *me = [[SEENetworkConnectionDocumentListItem alloc] init];
				me.user = [[TCMMMUserManager sharedInstance] me];
				NSString *cachedItemID = me.uid;
				id <SEEDocumentListItem> cachedItem = [lookupDictionary objectForKey:cachedItemID];
				if (cachedItem) {
					[self.availableItems addObject:cachedItem];
				} else {
					[self.availableItems addObject:me];
				}
			}

			{
				NSArray *sessions = [TCMMMPresenceManager sharedInstance].announcedSessions;
				for (TCMMMSession *session in sessions) {
					SEENetworkDocumentListItem *documentRepresentation = [[SEENetworkDocumentListItem alloc] init];
					documentRepresentation.documentSession = session;
					NSString *cachedItemID = documentRepresentation.uid;
					SEENetworkDocumentListItem *cachedItem = [lookupDictionary objectForKey:cachedItemID];
					if (cachedItem) {
						cachedItem.documentSession = session;
						[self.availableItems addObject:cachedItem];
					} else {
						[self.availableItems addObject:documentRepresentation];
					}
				}
			}
		}

		{
			SEENewDocumentListItem *newDocumentRepresentation = [[SEENewDocumentListItem alloc] init];
			NSString *cachedItemID = newDocumentRepresentation.uid;
			id <SEEDocumentListItem> cachedItem = [lookupDictionary objectForKey:cachedItemID];
			if (cachedItem) {
				[self.availableItems addObject:cachedItem];
			} else {
				[self.availableItems addObject:newDocumentRepresentation];
			}
		}

		{
			SEEOpenOtherDocumentListItem *openOtherItem = [[SEEOpenOtherDocumentListItem alloc] init];
			NSString *cachedItemID = openOtherItem.uid;
			id <SEEDocumentListItem> cachedItem = [lookupDictionary objectForKey:cachedItemID];
			if (cachedItem) {
				[self.availableItems addObject:cachedItem];
			} else {
				[self.availableItems addObject:openOtherItem];
			}
		}

		{
			SEEToggleRecentDocumentListItem *toggleRecentDocumentsItem = [[SEEToggleRecentDocumentListItem alloc] init];
			NSString *cachedItemID = toggleRecentDocumentsItem.uid;
			SEEToggleRecentDocumentListItem *cachedItem = [lookupDictionary objectForKey:cachedItemID];
			if (cachedItem) {
				[self.availableItems addObject:cachedItem];
			} else {
				toggleRecentDocumentsItem.showRecentDocuments = [[NSUserDefaults standardUserDefaults] boolForKey:@"DocumentListShowRecent"];
				[toggleRecentDocumentsItem addObserver:self forKeyPath:@"showRecentDocuments" options:0 context:SEENetworkDocumentBrowserEntriesObservingContext];
				self.toggleRecentItem = toggleRecentDocumentsItem;
				[self.availableItems addObject:toggleRecentDocumentsItem];
			}
			if (self.toggleRecentItem.showRecentDocuments) {
				NSArray *recentDocumentURLs = [[NSDocumentController sharedDocumentController] recentDocumentURLs];
				for (NSURL *url in recentDocumentURLs) {
					SEERecentDocumentListItem *recentDocumentItem = [[SEERecentDocumentListItem alloc] init];
					recentDocumentItem.fileURL = url;
					NSString *cachedItemID = recentDocumentItem.uid;
					id <SEEDocumentListItem> cachedItem = [lookupDictionary objectForKey:cachedItemID];
					if (cachedItem) {
						[self.availableItems addObject:cachedItem];
					} else {
						[self.availableItems addObject:recentDocumentItem];
					}
				}
			}
		}


		{
			NSArray *allConnections = [[SEEConnectionManager sharedInstance] entries];
			for (SEEConnection *connection in allConnections) {
				{
					SEENetworkConnectionDocumentListItem *connectionRepresentation = [[SEENetworkConnectionDocumentListItem alloc] init];
					connectionRepresentation.connection = connection;
					NSString *cachedItemID = connectionRepresentation.uid;
					SEENetworkConnectionDocumentListItem *cachedItem = [lookupDictionary objectForKey:cachedItemID];
					if (cachedItem) {
						cachedItem.connection = connection;
						[self.availableItems addObject:cachedItem];
					} else {
						[self.availableItems addObject:connectionRepresentation];
					}
				}

				NSArray *sessions = connection.announcedSessions;
				for (TCMMMSession *session in sessions) {
					SEENetworkDocumentListItem *documentRepresentation = [[SEENetworkDocumentListItem alloc] init];
					documentRepresentation.documentSession = session;
					documentRepresentation.beepSession = connection.BEEPSession;
					NSString *cachedItemID = documentRepresentation.uid;
					SEENetworkDocumentListItem *cachedItem = [lookupDictionary objectForKey:cachedItemID];
					if (cachedItem) {
						cachedItem.documentSession = session;
						cachedItem.beepSession = connection.BEEPSession;
						[self.availableItems addObject:cachedItem];
					} else {
						[self.availableItems addObject:documentRepresentation];
					}
				}
			}
		}

		{
			SEEConnectDocumentListItem *connectItem = [[SEEConnectDocumentListItem alloc] init];
			NSString *cachedItemID = connectItem.uid;
			id <SEEDocumentListItem> cachedItem = [lookupDictionary objectForKey:cachedItemID];
			if (cachedItem) {
				[self.availableItems addObject:cachedItem];
			} else {
				[self.availableItems addObject:connectItem];
			}
		}
	}
	[self didChangeValueForKey:@"availableItems"];
}


#pragma mark - Actions

- (IBAction)newDocument:(id)sender
{
	if (self.shouldCloseWhenOpeningDocument) {
		if ([NSApp modalWindow] == self.window) {
			[NSApp stopModalWithCode:NSModalResponseCancel];
		}
		[self close];
	}

	NSMenu *menu=[[[NSApp mainMenu] itemWithTag:FileMenuTag] submenu];
    NSMenuItem *menuItem=[menu itemWithTag:FileNewMenuItemTag];
    menu = [menuItem submenu];
    NSMenuItem *item = (NSMenuItem *)[menu itemWithTag:[[DocumentModeManager sharedInstance] tagForDocumentModeIdentifier:[[[DocumentModeManager sharedInstance] modeForNewDocuments] documentModeIdentifier]]];

	[[NSDocumentController sharedDocumentController] newDocumentWithModeMenuItem:item];
}


- (IBAction)triggerItemClickAction:(id)sender
{
	NSTableView *tableView = self.tableViewOutlet;
	id <SEEDocumentListItem> clickedItem = nil;
	if (sender == tableView) {
		NSInteger row = tableView.clickedRow;
		NSInteger column = tableView.clickedColumn;
		if (row > -1) {
			NSTableCellView *tableCell = [tableView viewAtColumn:column row:row makeIfNecessary:NO];
			clickedItem = tableCell.objectValue;
		}
	} else if ([sender conformsToProtocol:@protocol(SEEDocumentListItem)]) {
		clickedItem = sender;
	}

	if (clickedItem) {
		NSArray *selectedDocuments = self.documentListItemsArrayController.selectedObjects;
		if (! [selectedDocuments containsObject:clickedItem]) {
			[clickedItem itemAction:self.tableViewOutlet];
		}
	}
}


- (IBAction)triggerItemDoubleClickAction:(id)sender
{
	NSTableView *tableView = self.tableViewOutlet;
	id <SEEDocumentListItem> clickedItem = nil;
	if (sender == tableView) {
		NSInteger row = tableView.clickedRow;
		NSInteger column = tableView.clickedColumn;
		if (row > -1) {
			NSTableCellView *tableCell = [tableView viewAtColumn:column row:row makeIfNecessary:NO];
			clickedItem = tableCell.objectValue;
		}
	} else if ([sender conformsToProtocol:@protocol(SEEDocumentListItem)]) {
		clickedItem = sender;
	}

	if (clickedItem) {
		NSArray *selectedDocuments = self.documentListItemsArrayController.selectedObjects;
		if ([selectedDocuments containsObject:clickedItem]) {
			[selectedDocuments makeObjectsPerformSelector:@selector(itemAction:) withObject:self.tableViewOutlet];
		}
	}
}


#pragma mark - NSTableViewDelegate

- (NSView *)tableView:(NSTableView *)tableView viewForTableColumn:(NSTableColumn *)tableColumn row:(NSInteger)row {
	NSView *result = nil;

	NSArray *rowItems = self.availableItems;
	id rowItem = [rowItems objectAtIndex:row];

	if (tableColumn == nil && [rowItem isKindOfClass:SEENetworkConnectionDocumentListItem.class]) {
		result = [tableView makeViewWithIdentifier:@"Group" owner:self];
	} else if (tableColumn == nil && [rowItem isKindOfClass:SEEConnectDocumentListItem.class]) {
		result = [tableView makeViewWithIdentifier:@"Connect" owner:self];
	} else if ([rowItem isKindOfClass:SEEOpenOtherDocumentListItem.class] || [rowItem isKindOfClass:SEENewDocumentListItem.class]) {
		result = [tableView makeViewWithIdentifier:@"OtherItems" owner:self];
	} else if ([rowItem isKindOfClass:SEEToggleRecentDocumentListItem.class]) {
		result = [tableView makeViewWithIdentifier:@"ToggleRecent" owner:self];
	} else if ([rowItem isKindOfClass:SEERecentDocumentListItem.class]) {
		result = [tableView makeViewWithIdentifier:@"Document" owner:self];
	} else if ([rowItem isKindOfClass:SEENetworkDocumentListItem.class]) {
		result = [tableView makeViewWithIdentifier:@"NetworkDocument" owner:self];
	} else {
		result = [tableView makeViewWithIdentifier:@"Document" owner:self];
	}
	return result;
}

- (NSTableRowView *)tableView:(NSTableView *)tableView rowViewForRow:(NSInteger)row
{
	NSTableRowView * rowView = nil;
	NSArray *availableItems = self.availableItems;
	id <SEEDocumentListItem> itemRepresentation = [availableItems objectAtIndex:row];
	if ([itemRepresentation isKindOfClass:[SEENetworkConnectionDocumentListItem class]]) {
		rowView = [[SEEDocumentListGroupTableRowView alloc] init];

		if (row > 1) {
			BOOL drawTopLine = ! [[availableItems objectAtIndex:row - 1] isKindOfClass:[SEENetworkConnectionDocumentListItem class]];
			((SEEDocumentListGroupTableRowView *)rowView).drawTopLine = drawTopLine;
		}
	}
	return rowView;
}

- (void)tableView:(NSTableView *)tableView didAddRowView:(NSTableRowView *)rowView forRow:(NSInteger)row {
	NSArray *availableDocumentSession = self.availableItems;
	id documentRepresentation = [availableDocumentSession objectAtIndex:row];
	if ([documentRepresentation isKindOfClass:SEENetworkConnectionDocumentListItem.class]) {
		SEENetworkConnectionDocumentListItem *connectionRepresentation = (SEENetworkConnectionDocumentListItem *)documentRepresentation;
		NSTableCellView *tableCellView = [rowView.subviews objectAtIndex:0];

		NSImageView *userImageView = [[tableCellView subviews] objectAtIndex:1];

		userImageView.wantsLayer = YES;
		CALayer *userViewLayer = userImageView.layer;
		NSColor *changeColor = connectionRepresentation.connection.user.changeColor;
		userViewLayer.borderColor = [[NSColor colorWithCalibratedHue:changeColor.hueComponent saturation:0.85 brightness:1.0 alpha:1.0] CGColor];
		userViewLayer.borderWidth = NSHeight(userImageView.frame) / 16.0;
		userViewLayer.cornerRadius = NSHeight(userImageView.frame) / 2.0;
	}
}

- (BOOL)tableView:(NSTableView *)tableView isGroupRow:(NSInteger)row
{
	BOOL result = NO;
	NSArray *availableDocumentSession = self.availableItems;
	id documentRepresentation = [availableDocumentSession objectAtIndex:row];
	if ([documentRepresentation isKindOfClass:SEENetworkConnectionDocumentListItem.class] ||
		[documentRepresentation isKindOfClass:SEEConnectDocumentListItem.class]) {
		result = YES;
	}
	return result;
}

//- (BOOL)tableView:(NSTableView *)tableView shouldSelectRow:(NSInteger)row
//{
//	BOOL result = NO;
//	NSArray *availableDocumentSession = self.availableItems;
//	id documentRepresentation = [availableDocumentSession objectAtIndex:row];
//	if ([documentRepresentation isKindOfClass:SEENetworkDocumentListItem.class]) {
//		result = YES;
//	}
//	return result;
//}

- (void)tableViewSelectionDidChange:(NSNotification *)notification
{
	NSIndexSet *selectedIndices = self.tableViewOutlet.selectedRowIndexes;
	[selectedIndices enumerateIndexesUsingBlock:^(NSUInteger row, BOOL *stop) {
		id documentRepresentation = [self.availableItems objectAtIndex:row];
		if (! ([documentRepresentation isKindOfClass:SEENetworkDocumentListItem.class] || [documentRepresentation isKindOfClass:SEERecentDocumentListItem.class])) {
			[self.tableViewOutlet deselectRow:row];
		}
	}];
}

- (CGFloat)tableView:(NSTableView *)tableView heightOfRow:(NSInteger)row {
	CGFloat rowHeight = 28.0;

	NSArray *availableDocumentSession = self.availableItems;
	id documentRepresentation = [availableDocumentSession objectAtIndex:row];
	if ([documentRepresentation isKindOfClass:SEENetworkConnectionDocumentListItem.class]) {
		rowHeight = 46.0;
	} else if ([documentRepresentation isKindOfClass:SEEToggleRecentDocumentListItem.class]) {
		rowHeight = 28.0;
	} else if ([documentRepresentation isKindOfClass:SEEConnectDocumentListItem.class]) {
		rowHeight = 42.0;
	}
	return rowHeight;
}

@end