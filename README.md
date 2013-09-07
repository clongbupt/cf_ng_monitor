admin_ui
===

## application.html 

In the html file, I mainly analyse the DOM structure:

	|-- titleBar

		|-- userMenu    onclick   user logout

	|-- menuBar   Below are the main commponents, each will represent a tab to let the user click

		|-- CloudControllers

		|-- HealthManagers

		|-- Gateways

		|-- Routers

		|-- DropletExecutionAgents

		|-- Applications

		|-- Users

		|-- Spaces    **NEW**

		|-- Components

		|-- Logs

		|-- RefreshButton

	|-- content  

		|-- loadingPage   If the data is not ready, the user will see the loadingPage

		|-- errorPage     If we try serveral times, but still failed to get the data, the user will see the errorPage

		|-- CloudcontrollersPage   each component will have the same structure

			|-- TableContainer     jQuery plugin datatable

				|-- Table_wrapper

		|-- HealthManagersPage

		|-- GatewaysPage

		|-- DropletExecutionAgentsPage

		|-- ApplicationsPage

		|-- UsersPage

		|-- SpacePage   **NEW**

		|-- ComponentsPage

		|-- LogsPage

## application.js 

It will contains two parts, the first is using the jQuery datatable plugin to create different tables and render it, the other part is handling the context to communicate with web service, to fetch the data, cache it and convert it to display with datatable.

### Application Object

It takes the majority job in the browser context. Generally speaking, it contains serveral global variables and functions, some of the functions are similar to handle different components, such as router, dea, while some of them are useful tools, such as generate table based on datatable, communicate with web service based on ajax.

#### Global Variables

In application object there are two main global variables:

	* ID__COMPONENTS_NAME   it will used to be the unique identifications for each components

	* URL__COMPONENTS_NAME  it will used to generate the right URL to communicate with web service and fetch the specific component data.

#### Initialize

Once the user login, he will see a default tab clicked and the cloud_controller component info. This section will try to explain what is going behind it.

Every time when user login, the application object will invoke the initialize funtion, in one word it will init all the things you see in the browser. In details it contains serveral parts:

	1. bind the click / mouseover / mouseout event to the anchor, so once is is triggered by the user we can reponse it by invoke the target function, such as when user clicked any tabs, we will invoke the handleTabClicked("component_id") function

	2. initialize each component by invoke those functions : initialize(component_name)Page  such as initializeCloudControllersPage

	3. bind` an click event on RefreshButton, it will invoke the handleTabClicked("RefreshButton") to refresh all the data

	4. show Loading Page

	5. initializeCache this will create an array to store some data and it also invoke an important function : refreshData()

	6. Ata last, trigger an click event on CloudController, so everytime we login will see the cloud_controller data

#### A Circle of Each Component

Above the Initialize Section, we already bind the click event on each tab. And it will call a refresh*Page() function. We pick the cloud_contoler component as an example, so we will call the refreshCloudControllersPage(), if we search we will find the function, and near it there will be some other functions have the same component id, here is what i got, and i will try to describe it in a correct flow :

	* refreshCloudControllersPage   reponse to the tab click event, and call the getData function and when we got the right data, we will call the refreshTab() function and pass the data, in this function we will call the getCloudControllersTableData

	* getCloudControllersTableData   handle the data that got from the ajax response and convert it to suit for the datatable, it will call the getTableData function, in this function we will call the getCloudControllersRow

	* getCloudControllersRow   it will handle each row of the table, we have to push right data into the right field, And if there is not data suitable, we have to addEmptyElementstoArray.

	* cloudControllerClicked   it will handle the row click event, which is bind by datatable

	* handleCloudControllerClicked  it will render an display container right below the table in the broswer, and we aslo have to organize some data for rendering. 

##### refreshTab()

This function will handle the ajax response, If where is an error in response, if the response is an array and there is only one error item of the array, it also will get the error page. 

If the response is just right, it will call the function : getCloudControllerData(results)

####  getTableData(results, type)

This function is trying to split the results which got from the ajax response and push it into each row of the datatable.

It will call the getCloudControllerRow(row, item) item is just one item of the results.

### The Mapping of Table Column Name and Column Data

In application object there is still many functions we do not mentioned. This section we will try to explain the sollect of such functions : get*Columns

These functions are the definition of each table of each component. And as we mentioned before, we already know how to get the data from the web service and convert it into the right field of the table.

But there is still a mapping between the column data and the column name. In the initialize function we will initialize each component, and each of them will call a function like that initialize*Page, in this function all of them will call a createTable function. 

In the createTable function, we will read the data in get*Columns function, and configure it will datatable api, with datatable api, we will easily map the column name with column data. 

#### Other useful functions

##### handleTabClicked("component_id")

Actually this function is very simple and clear, there are only two lines in this funtion, the first line is seting the tab selected to make friendly response to the user and the second line is invoking another important function : refresh(component_id)Page(), such as refreshCloudControllersPage()

#### refreshData

This function will fill some data into the cache array, which is generated in the initialize function and call a function named getData for each component.

#### getData (uri, reload)

In getData function the most important thing is just like its name, get the data we need. It is based on jQuery ajax API, make an ajax request with the uri passed as an argument. Of course it will handle 

#### format*(values)

In application object, there are many tool functions. Format* are very userful tools, when we try to render the data with a friendly formate, such as Date, Number, URIs...

## admin.rb

It is the main file of the web service in this project. In this file, mostly it handles those things:

	1. User Nats to request 'vcap.component.discover' and get all the response, which contains each component varz address, store those url address in the 'data.json' file

	2. Dispatch every reqeust to the right functions with a URL router

	3. For some request like '/cloud_controller' '/dea', make another http request to the varz api to get the data and respond it directly to the url who request.

	4. Handle the '/fetch' request,  it will analyse the query string and make another http request to get the data.

	5. Handle the '/logs' 'log' request, it will open the log file and read the content, then respond to the browser, and more than that, it supports pagination. 

	6. For some components in cloud foundry ng, we cloud not get the varz info no more, so we add new functions to get those info. Actually, we use DataMapper to access the database to get right data.
