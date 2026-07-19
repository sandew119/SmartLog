import 'package:flutter/material.dart';
import '../utils/calculator.dart';

class ManualCalculatorScreen extends StatefulWidget {
  const ManualCalculatorScreen({super.key});

  @override
  State<ManualCalculatorScreen> createState() =>
      _ManualCalculatorScreenState();
}

class _ManualCalculatorScreenState
    extends State<ManualCalculatorScreen> {

  final TextEditingController diameterController =
      TextEditingController();

  final TextEditingController lengthController =
      TextEditingController();


  double? volume;


  void calculate() {

    final diameter =
        double.tryParse(diameterController.text);

    final length =
        double.tryParse(lengthController.text);


    if (diameter == null ||
        length == null ||
        diameter <= 0 ||
        length <= 0) {

      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(
          content: Text(
            "Enter valid values",
          ),
        ),
      );

      return;
    }


    final result =
        Calculator.calculateVolume(
          diameter: diameter,
          lengthFeet: length,
        );


    setState(() {
      volume = result;
    });
  }



  void clear() {

    diameterController.clear();
    lengthController.clear();

    setState(() {
      volume = null;
    });

  }



  @override
  void dispose() {

    diameterController.dispose();
    lengthController.dispose();

    super.dispose();

  }



  @override
  Widget build(BuildContext context) {

    return Scaffold(

      appBar: AppBar(
        title: const Text(
          "Manual Calculator",
        ),
        centerTitle: true,
      ),


      body: Padding(

        padding: const EdgeInsets.all(20),

        child: Column(

          children: [


            TextField(

              controller: diameterController,

              keyboardType:
                  TextInputType.number,

              decoration:
                  const InputDecoration(

                    labelText:
                        "Diameter (inches)",

                    border:
                        OutlineInputBorder(),

                    prefixIcon:
                        Icon(Icons.circle),

                  ),
            ),



            const SizedBox(height: 15),



            TextField(

              controller: lengthController,

              keyboardType:
                  TextInputType.number,

              decoration:
                  const InputDecoration(

                    labelText:
                        "Length (feet)",

                    border:
                        OutlineInputBorder(),

                    prefixIcon:
                        Icon(Icons.straighten),

                  ),
            ),



            const SizedBox(height: 25),



            Row(

              children: [


                Expanded(

                  child: ElevatedButton(

                    onPressed: calculate,

                    style:
                        ElevatedButton.styleFrom(

                          minimumSize:
                              const Size(
                                double.infinity,
                                50,
                              ),

                        ),

                    child:
                        const Text(
                          "Calculate",
                        ),

                  ),

                ),



                const SizedBox(width: 10),



                ElevatedButton(

                  onPressed: clear,

                  style:
                      ElevatedButton.styleFrom(

                        backgroundColor:
                            Colors.red,

                      ),

                  child:
                      const Text(
                        "Clear",
                      ),

                ),

              ],

            ),



            const SizedBox(height: 30),



            if (volume != null)

              Container(

                width:
                    double.infinity,

                padding:
                    const EdgeInsets.all(20),

                decoration:
                    BoxDecoration(

                      color:
                          Colors.blue.shade50,

                      borderRadius:
                          BorderRadius.circular(
                            15,
                          ),

                    ),

                child:
                    Column(

                      children: [

                        const Text(
                          "Calculated Volume",
                          style:
                              TextStyle(
                                fontSize:18,
                                fontWeight:
                                    FontWeight.bold,
                              ),
                        ),


                        const SizedBox(height:10),


                        Text(

                          "${volume!.toStringAsFixed(3)} ft³",

                          style:
                              const TextStyle(

                                fontSize:30,

                                fontWeight:
                                    FontWeight.bold,

                              ),

                        ),

                      ],

                    ),

              ),

          ],

        ),

      ),

    );

  }

}