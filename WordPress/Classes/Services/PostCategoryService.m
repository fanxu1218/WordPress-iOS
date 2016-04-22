#import "PostCategoryService.h"
#import "PostCategory.h"
#import "Blog.h"
#import "RemotePostCategory.h"
#import "ContextManager.h"
#import "TaxonomyServiceRemote.h"
#import "TaxonomyServiceRemoteREST.h"
#import "TaxonomyServiceRemoteXMLRPC.h"
#import "RemoteTaxonomyPaging.h"

NS_ASSUME_NONNULL_BEGIN

@implementation PostCategoryService

- (NSError *)serviceErrorNoBlog
{
    return [NSError errorWithDomain:NSStringFromClass([self class])
                               code:PostCategoryServiceErrorsBlogNotFound
                           userInfo:nil];
}

- (PostCategory *)newCategoryForBlog:(Blog *)blog
{
    PostCategory *category = [NSEntityDescription insertNewObjectForEntityForName:[PostCategory entityName]
                                                       inManagedObjectContext:self.managedObjectContext];
    category.blog = blog;
    return category;
}

- (PostCategory *)newCategoryForBlogObjectID:(NSManagedObjectID *)blogObjectID {
    Blog *blog = [self blogWithObjectID:blogObjectID];
    return [self newCategoryForBlog:blog];
}

- (BOOL)existsName:(NSString *)name forBlogObjectID:(NSManagedObjectID *)blogObjectID withParentId:(nullable NSNumber *)parentId
{
    Blog *blog = [self blogWithObjectID:blogObjectID];

    NSPredicate *predicate = [NSPredicate predicateWithFormat:@"(categoryName like %@) AND (parentID = %@)", name,
                              (parentId ? parentId : @0)];

    NSSet *items = [blog.categories filteredSetUsingPredicate:predicate];

    if ((items != nil) && (items.count > 0)) {
        // Already exists
        return YES;
    }

    return NO;
}

- (nullable PostCategory *)findWithBlogObjectID:(NSManagedObjectID *)blogObjectID andCategoryID:(NSNumber *)categoryID
{
    NSPredicate *predicate = [NSPredicate predicateWithFormat:@"categoryID == %@", categoryID];
    return [self findWithBlogObjectID:blogObjectID predicate:predicate];
}

- (nullable PostCategory *)findWithBlogObjectID:(NSManagedObjectID *)blogObjectID parentID:(nullable NSNumber *)parentID andName:(NSString *)name
{
    NSPredicate *predicate = [NSPredicate predicateWithFormat:@"(categoryName like %@) AND (parentID = %@)", name,
                              (parentID ? parentID : @0)];
    return [self findWithBlogObjectID:blogObjectID predicate:predicate];
}

- (nullable PostCategory *)findWithBlogObjectID:(NSManagedObjectID *)blogObjectID predicate:(NSPredicate *)predicate
{
    Blog *blog = [self blogWithObjectID:blogObjectID];

    NSSet *results = [blog.categories filteredSetUsingPredicate:predicate];
    return [results anyObject];

}

- (nullable PostCategory *)createOrReplaceFromDictionary:(NSDictionary *)categoryInfo
                            forBlogObjectID:(NSManagedObjectID *)blogObjectID
{
    Blog *blog = [self blogWithObjectID:blogObjectID];

    if ([categoryInfo objectForKey:@"categoryId"] == nil) {
        return nil;
    }
    if ([categoryInfo objectForKey:@"categoryName"] == nil) {
        return nil;
    }

    PostCategory *category = [self findWithBlogObjectID:blog.objectID andCategoryID:[[categoryInfo objectForKey:@"categoryId"] numericValue]];

    if (category == nil) {
        category = [self newCategoryForBlog:blog];
    }

    category.categoryID     = [[categoryInfo objectForKey:@"categoryId"] numericValue];
    category.categoryName   = [categoryInfo objectForKey:@"categoryName"];
    category.parentID       = [[categoryInfo objectForKey:@"parentId"] numericValue];

    return category;
}

- (void)syncCategoriesForBlog:(Blog *)blog
                      success:(nullable void (^)())success
                      failure:(nullable void (^)(NSError *error))failure
{
    id<TaxonomyServiceRemote> remote = [self remoteForBlog:blog];
    NSManagedObjectID *blogID = blog.objectID;
    [remote getCategoriesWithSuccess:^(NSArray *categories) {
                               [self.managedObjectContext performBlock:^{
                                   Blog *blog = (Blog *)[self.managedObjectContext existingObjectWithID:blogID error:nil];
                                   if (!blog) {
                                       if (failure) {
                                           failure([self serviceErrorNoBlog]);
                                       }
                                       return;
                                   }
                                   [self mergeCategories:categories
                                                 forBlog:blog
                                       completionHandler:^(NSArray<PostCategory *> *postCategories) {
                                           if (success) {
                                               success();
                                           }
                                       }];
                               }];
                           } failure:failure];
}

- (void)syncCategoriesForBlog:(Blog *)blog
                       number:(nullable NSNumber *)number
                       offset:(nullable NSNumber *)offset
                      success:(nullable void (^)(NSArray <PostCategory *> *categories))success
                      failure:(nullable void (^)(NSError *error))failure
{
    id<TaxonomyServiceRemote> remote = [self remoteForBlog:blog];
    RemoteTaxonomyPaging *paging = [[RemoteTaxonomyPaging alloc] init];
    paging.number = number ?: @(100);
    paging.offset = offset ?: @(0);
    NSManagedObjectID *blogID = blog.objectID;
    [remote getCategoriesWithPaging:paging
                            success:^(NSArray<RemotePostCategory *> *categories) {
                                [self.managedObjectContext performBlock:^{
                                    Blog *blog = (Blog *)[self.managedObjectContext existingObjectWithID:blogID error:nil];
                                    if (!blog) {
                                        if (failure) {
                                            failure([self serviceErrorNoBlog]);
                                        }
                                        return;
                                    }
                                    [self mergeCategories:categories
                                                  forBlog:blog
                                        completionHandler:^(NSArray<PostCategory *> *postCategories) {
                                            if (success) {
                                                success(postCategories);
                                            }
                                        }];
                                }];
                            } failure:failure];
}

- (void)createCategoryWithName:(NSString *)name
        parentCategoryObjectID:(nullable NSManagedObjectID *)parentCategoryObjectID
               forBlogObjectID:(NSManagedObjectID *)blogObjectID
                       success:(nullable void (^)(PostCategory *category))success
                       failure:(nullable void (^)(NSError *error))failure
{
    NSParameterAssert(name != nil);
    Blog *blog = [self blogWithObjectID:blogObjectID];

    PostCategory *parent = [self categoryWithObjectID:parentCategoryObjectID];

    RemotePostCategory *remoteCategory = [RemotePostCategory new];
    remoteCategory.parentID = parent.categoryID;
    remoteCategory.name = name;

    id<TaxonomyServiceRemote> remote = [self remoteForBlog:blog];
    [remote createCategory:remoteCategory
                   success:^(RemotePostCategory *receivedCategory) {
                       [self.managedObjectContext performBlock:^{
                           Blog *blog = [self blogWithObjectID:blogObjectID];
                           if (!blog) {
                               if (failure) {
                                   failure([self serviceErrorNoBlog]);
                               }
                               return;
                           }
                           PostCategory *newCategory = [self newCategoryForBlog:blog];
                           newCategory.categoryID = receivedCategory.categoryID;
                           if ([remote isKindOfClass:[TaxonomyServiceRemoteXMLRPC class]]) {
                               // XML-RPC only returns ID, let's fetch the new category as
                               // filters might change the content
                               [self syncCategoriesForBlog:blog success:nil failure:nil];
                               newCategory.categoryName = remoteCategory.name;
                               newCategory.parentID = remoteCategory.parentID;
                           } else {
                               newCategory.categoryName = receivedCategory.name;
                               newCategory.parentID = receivedCategory.parentID;
                           }
                           if (newCategory.parentID == nil) {
                               newCategory.parentID = @0;
                           }
                           [[ContextManager sharedInstance] saveContext:self.managedObjectContext];
                           if (success) {
                               success(newCategory);
                           }
                       }];
                   } failure:failure];
}

- (void)mergeCategories:(NSArray <RemotePostCategory *> *)remoteCategories forBlog:(Blog *)blog completionHandler:(nullable void (^)(NSArray <PostCategory *> *categories))completion
{
    NSSet *remoteSet = [NSSet setWithArray:[remoteCategories valueForKey:@"categoryID"]];
    NSSet *localSet = [blog.categories valueForKey:@"categoryID"];
    NSMutableSet *toDelete = [localSet mutableCopy];
    [toDelete minusSet:remoteSet];

    if ([toDelete count] > 0) {
        for (PostCategory *category in blog.categories) {
            if ([toDelete containsObject:category.categoryID]) {
                [self.managedObjectContext deleteObject:category];
            }
        }
    }
    
    NSMutableArray *categories = [NSMutableArray arrayWithCapacity:remoteCategories.count];
    
    for (RemotePostCategory *remoteCategory in remoteCategories) {
        PostCategory *category = [self findWithBlogObjectID:blog.objectID andCategoryID:remoteCategory.categoryID];
        if (!category) {
            category = [self newCategoryForBlog:blog];
            category.categoryID = remoteCategory.categoryID;
        }
        category.categoryName = remoteCategory.name;
        category.parentID = remoteCategory.parentID;
        
        [categories addObject:category];
    }

    [[ContextManager sharedInstance] saveContext:self.managedObjectContext];

    if (completion) {
        completion(categories);
    }
}

- (nullable Blog *)blogWithObjectID:(nullable NSManagedObjectID *)objectID
{
    if (objectID == nil) {
        return nil;
    }

    NSError *error;
    Blog *blog = (Blog *)[self.managedObjectContext existingObjectWithID:objectID error:&error];
    if (error) {
        DDLogError(@"Error when retrieving Blog by ID: %@", error);
        return nil;
    }

    return blog;
}

- (nullable PostCategory *)categoryWithObjectID:(nullable NSManagedObjectID *)objectID
{
    if (objectID == nil) {
        return nil;
    }

    NSError *error;
    PostCategory *category = (PostCategory *)[self.managedObjectContext existingObjectWithID:objectID error:&error];
    if (error) {
        DDLogError(@"Error when retrieving Category by ID: %@", error);
        return nil;
    }

    return category;
}

- (id<TaxonomyServiceRemote>)remoteForBlog:(Blog *)blog {
    if (blog.restApi) {
        return [[TaxonomyServiceRemoteREST alloc] initWithApi:blog.restApi siteID:blog.dotComID];
    } else {
        return [[TaxonomyServiceRemoteXMLRPC alloc] initWithApi:blog.api username:blog.username password:blog.password];
    }
}

@end

NS_ASSUME_NONNULL_END
